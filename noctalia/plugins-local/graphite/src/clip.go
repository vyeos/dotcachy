package main

// Clipboard history store. The event process runs `wl-paste --watch graphite clip DIR
// store`, so every selection change calls store once; the clip panel calls the rest.
// This is the only writer of DIR/clip-index.json (guarded by a flock).
//
//	graphite clip DIR store|copy ID|pin ID|del ID|clear
//
// clip-index.json is newest first.

import (
	"bytes"
	"crypto/sha1"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"
)

const (
	clipMaxUnpinned = 100
	clipTextMax     = 8000 // longer text lives in its own file; this much is indexed
	clipSkipType    = "x-kde-passwordManagerHint"
)

type clipItem struct {
	ID     int64  `json:"id"`
	Kind   string `json:"kind"`
	T      int64  `json:"t"`
	Size   int    `json:"size"`
	Hash   string `json:"hash"`
	Pinned bool   `json:"pinned"`
	Text   string `json:"text,omitempty"`
	Full   string `json:"full,omitempty"`
	File   string `json:"file,omitempty"`
	W      uint32 `json:"w,omitempty"`
	H      uint32 `json:"h,omitempty"`
}

type clipStore struct {
	path  string
	img   string
	items []*clipItem
}

func openClipStore(root string) *clipStore {
	s := &clipStore{path: filepath.Join(root, "clip-index.json"), img: filepath.Join(root, "clip")}
	os.MkdirAll(s.img, 0o755)
	// Held until the process exits, which releases it.
	if lock, err := os.OpenFile(filepath.Join(root, "clip.lock"), os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
		syscall.Flock(int(lock.Fd()), syscall.LOCK_EX)
	}
	if !loadJSON(s.path, &s.items) {
		s.items = nil
	}
	return s
}

func (s *clipStore) remove(item *clipItem) {
	for i, it := range s.items {
		if it == item {
			s.items = append(s.items[:i], s.items[i+1:]...)
			return
		}
	}
}

func (s *clipStore) drop(item *clipItem) {
	s.remove(item)
	for _, p := range []string{item.File, item.Full} {
		if p != "" {
			os.Remove(p)
		}
	}
}

func (s *clipStore) toTop(item *clipItem) {
	s.remove(item)
	s.items = append([]*clipItem{item}, s.items...)
}

func (s *clipStore) find(id string) *clipItem {
	for _, it := range s.items {
		if strconv.FormatInt(it.ID, 10) == id {
			return it
		}
	}
	return nil
}

func (s *clipStore) save() {
	var unpinned []*clipItem
	for _, it := range s.items {
		if !it.Pinned {
			unpinned = append(unpinned, it)
		}
	}
	if len(unpinned) > clipMaxUnpinned {
		for _, old := range unpinned[clipMaxUnpinned:] {
			s.drop(old)
		}
	}
	if s.items == nil {
		s.items = []*clipItem{}
	}
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if enc.Encode(s.items) == nil && writeAtomic(s.path, b.Bytes()) == nil {
		fmt.Println("changed")
	}
}

// add returns the entry and whether it's new; a repeat just moves to the top.
func (s *clipStore) add(item clipItem, data []byte) (*clipItem, bool) {
	sum := sha1.Sum(data)
	hash := hex.EncodeToString(sum[:])
	now := time.Now()
	for _, old := range s.items {
		if old.Hash == hash {
			old.T = now.Unix()
			s.toTop(old)
			return old, false
		}
	}
	item.ID, item.T, item.Size, item.Hash = now.UnixMilli(), now.Unix(), len(data), hash
	s.items = append([]*clipItem{&item}, s.items...)
	return &item, true
}

func wlPaste(mime string) []byte {
	return outputBytes(5*time.Second, nil, "wl-paste", "--no-newline", "--type", mime)
}

func pngSize(data []byte) (uint32, uint32) {
	if len(data) >= 24 && bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")) {
		return binary.BigEndian.Uint32(data[16:20]), binary.BigEndian.Uint32(data[20:24])
	}
	return 0, 0
}

func (s *clipStore) store() bool {
	io.Copy(io.Discard, os.Stdin) // drain what wl-paste handed us
	types := strings.Fields(output(5*time.Second, "wl-paste", "--list-types"))
	if len(types) == 0 {
		return false
	}
	var img string
	var texty []string
	for _, t := range types {
		if t == clipSkipType {
			return false
		}
		if t == "image/png" || (img == "" && strings.HasPrefix(t, "image/")) {
			img = t
		}
		if strings.HasPrefix(t, "text/plain") || t == "UTF8_STRING" || t == "STRING" || t == "TEXT" {
			texty = append(texty, t)
		}
	}
	// Browsers offer an image alongside text/html; a copied picture has no plain text.
	if img != "" && len(texty) == 0 {
		return s.storeImage(img)
	}
	if len(texty) == 0 {
		return false
	}
	pref := texty[0]
	for _, t := range texty {
		if strings.Contains(strings.ToLower(t), "utf-8") {
			pref = t
			break
		}
	}
	data := wlPaste(pref)
	if len(bytes.TrimFunc(data, unicode.IsSpace)) == 0 {
		return false
	}
	preview := data
	if len(preview) > clipTextMax {
		preview = preview[:clipTextMax]
	}
	item, isNew := s.add(clipItem{Kind: "text", Text: strings.ToValidUTF8(string(preview), "")}, data)
	if isNew && len(data) > clipTextMax {
		item.Full = filepath.Join(s.img, fmt.Sprintf("%d.txt", item.ID))
		os.WriteFile(item.Full, data, 0o644)
	}
	return true
}

func (s *clipStore) storeImage(mime string) bool {
	data := wlPaste(mime)
	if len(data) == 0 {
		return false
	}
	if mime != "image/png" {
		if conv := outputBytes(5*time.Second, data, "magick", "-", "png:-"); len(conv) > 0 {
			data = conv
		}
	}
	w, h := pngSize(data)
	item, isNew := s.add(clipItem{Kind: "image", W: w, H: h}, data)
	if isNew {
		item.File = filepath.Join(s.img, fmt.Sprintf("%d.png", item.ID))
		os.WriteFile(item.File, data, 0o644)
	}
	return true
}

func (s *clipStore) copy(id string) bool {
	item := s.find(id)
	if item == nil {
		return false
	}
	var data []byte
	mime := "text/plain;charset=utf-8"
	var err error
	switch {
	case item.Kind == "image":
		data, err = os.ReadFile(item.File)
		mime = "image/png"
	case item.Full != "":
		data, err = os.ReadFile(item.Full)
	default:
		data = []byte(item.Text)
	}
	if err != nil {
		return false
	}
	cmd := exec.Command("wl-copy", "--type", mime)
	cmd.Stdin = bytes.NewReader(data)
	cmd.Run()
	item.T = time.Now().Unix()
	s.toTop(item)
	return true
}

func cmdClip(args []string) {
	if len(args) < 2 {
		os.Exit(2)
	}
	s := openClipStore(args[0])
	id := ""
	if len(args) > 2 {
		id = args[2]
	}
	changed := false
	switch args[1] {
	case "store":
		changed = s.store()
	case "copy":
		changed = s.copy(id)
	case "pin":
		if item := s.find(id); item != nil {
			item.Pinned, changed = !item.Pinned, true
		}
	case "del":
		if item := s.find(id); item != nil {
			s.drop(item)
			changed = true
		}
	case "clear":
		for _, item := range append([]*clipItem(nil), s.items...) {
			if !item.Pinned {
				s.drop(item)
			}
		}
		changed = true
	}
	if changed {
		s.save()
	}
}
