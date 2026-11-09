package main

// Creates and edits browser-backed web apps.
//
//	graphite webapp NAME URL [ICON]
//	graphite webapp-rename ID NAME | webapp-icon ID ICON | webapp-delete ID
//
// ICON is a local path or an image link. Without it the icon is looked up on the
// site: web manifest, <link> icons, the usual root paths, then DuckDuckGo's favicon
// service as a last resort (the only time the host name leaves for a third party).

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	webAppBrowser = "brave-origin" // --app needs a Chromium browser, whatever the default is
	webUA         = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
	pageMax       = 2_000_000
	iconMax       = 5_000_000
	iconBudget    = 25 * time.Second // the panel gives up at 40 s
	goodSize      = 96               // stop looking once an icon is at least this big
	minSize       = 16
	iconSize      = 256
)

func webAppsDir() string  { return homeDir() + "/.local/share/applications" }
func webIconsDir() string { return homeDir() + "/.local/share/icons/webapps" }

var (
	wsRe      = regexp.MustCompile(`\s`)
	slugRe    = regexp.MustCompile(`[^a-z0-9]+`)
	ctrlRe    = regexp.MustCompile(`[\x00-\x1f\x7f]`)
	httpRe    = regexp.MustCompile(`(?i)^https?://`)
	sizesRe   = regexp.MustCompile(`(\d+)x\d+`)
	tagRe     = regexp.MustCompile(`(?is)<(link|base)\b([^>]*)>`)
	attrRe    = regexp.MustCompile(`(?is)([a-z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))`)
	webIDRe   = regexp.MustCompile(`^webapp-[a-z0-9-]+$`)
	safeChars = "%:/?#[]@!&'()*+,;=~-._"
)

func percentEscape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte(safeChars, c) >= 0 {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// normalizeURL adds a scheme and percent-encodes what a desktop file's Exec= could
// trip over ($, backtick, quotes). Returns "" when it isn't a usable web address.
func normalizeURL(raw string) (string, string) {
	raw = strings.TrimSpace(raw)
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	if wsRe.MatchString(raw) {
		return "", ""
	}
	p, err := url.Parse(raw)
	if err != nil || (p.Scheme != "http" && p.Scheme != "https") {
		return "", ""
	}
	host := p.Hostname()
	if !strings.Contains(host, ".") && host != "localhost" {
		return "", ""
	}
	rest := raw[strings.Index(raw, "://")+3:]
	rest, fragment, hasFrag := strings.Cut(rest, "#")
	rest, query, hasQuery := strings.Cut(rest, "?")
	_, path, hasPath := strings.Cut(rest, "/")
	out := p.Scheme + "://" + p.Host + "/"
	if hasPath {
		out += percentEscape(path)
	}
	if hasQuery && query != "" {
		out += "?" + percentEscape(query)
	}
	if hasFrag && fragment != "" {
		out += "#" + percentEscape(fragment)
	}
	return out, host
}

func webAppID(name, host string) string {
	slug := strings.Trim(slugRe.ReplaceAllString(strings.ToLower(name), "-"), "-")
	if slug == "" {
		slug = strings.Trim(slugRe.ReplaceAllString(strings.ToLower(host), "-"), "-")
	}
	return "webapp-" + slug
}

func fetch(target string, limit int64, deadline time.Time) ([]byte, string) {
	left := time.Until(deadline)
	if left <= 0 {
		return nil, target
	}
	if left > 6*time.Second {
		left = 6 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), left)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", target, nil)
	if err != nil {
		return nil, target
	}
	req.Header.Set("User-Agent", webUA)
	req.Header.Set("Accept", "*/*")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, target
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, target
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, target
	}
	return data, resp.Request.URL.String()
}

func declaredSize(sizes, href, kind string, fallback int) int {
	if strings.HasSuffix(strings.ToLower(strings.SplitN(href, "?", 2)[0]), ".svg") || strings.Contains(kind, "svg") {
		return 512
	}
	sizes = strings.ToLower(sizes)
	if strings.Contains(sizes, "any") {
		return 512
	}
	best := 0
	for _, m := range sizesRe.FindAllStringSubmatch(sizes, -1) {
		if n, _ := strconv.Atoi(m[1]); n > best {
			best = n
		}
	}
	if best > 0 {
		return best
	}
	return fallback
}

func resolveURL(base, ref string) string {
	b, err := url.Parse(base)
	if err != nil {
		return ""
	}
	r, err := url.Parse(strings.TrimSpace(ref))
	if err != nil {
		return ""
	}
	return b.ResolveReference(r).String()
}

type iconCandidate struct {
	url  string
	size int
}

// iconCandidates lists the icon URLs a site offers, biggest declared size first.
func iconCandidates(target string, deadline time.Time) []string {
	var found []iconCandidate
	page, final := fetch(target, pageMax, deadline)
	if page != nil {
		base := final
		var hrefs []iconCandidate
		manifest := ""
		for _, tag := range tagRe.FindAllStringSubmatch(string(page), -1) {
			attrs := map[string]string{}
			for _, a := range attrRe.FindAllStringSubmatch(tag[2], -1) {
				attrs[strings.ToLower(a[1])] = html.UnescapeString(a[2] + a[3] + a[4])
			}
			href := attrs["href"]
			if href == "" {
				continue
			}
			if strings.EqualFold(tag[1], "base") {
				if base == final {
					base = resolveURL(final, href)
				}
				continue
			}
			rel := " " + strings.Join(strings.Fields(strings.ToLower(attrs["rel"])), " ") + " "
			switch {
			case strings.Contains(rel, " manifest "):
				manifest = href
			case strings.Contains(rel, " apple-touch-icon ") || strings.Contains(rel, " apple-touch-icon-precomposed "):
				hrefs = append(hrefs, iconCandidate{href, declaredSize(attrs["sizes"], href, attrs["type"], 180)})
			case strings.Contains(rel, " icon "):
				hrefs = append(hrefs, iconCandidate{href, declaredSize(attrs["sizes"], href, attrs["type"], 32)})
			}
		}
		for _, h := range hrefs {
			found = append(found, iconCandidate{resolveURL(base, h.url), h.size})
		}
		if manifest != "" {
			if raw, mfinal := fetch(resolveURL(base, manifest), pageMax, deadline); raw != nil {
				var m struct {
					Icons []struct {
						Src     string `json:"src"`
						Sizes   string `json:"sizes"`
						Type    string `json:"type"`
						Purpose string `json:"purpose"`
					} `json:"icons"`
				}
				if json.Unmarshal(raw, &m) == nil {
					for _, ic := range m.Icons {
						if ic.Src != "" && !strings.Contains(ic.Purpose, "monochrome") {
							found = append(found, iconCandidate{resolveURL(mfinal, ic.Src), declaredSize(ic.Sizes, ic.Src, ic.Type, 192)})
						}
					}
				}
			}
		}
	}
	found = append(found, iconCandidate{resolveURL(final, "/apple-touch-icon.png"), 180}, iconCandidate{resolveURL(final, "/favicon.ico"), 16})
	sort.SliceStable(found, func(i, j int) bool { return found[i].size > found[j].size })
	seen := map[string]bool{}
	var out []string
	for _, c := range found {
		if !seen[c.url] && (strings.HasPrefix(c.url, "http://") || strings.HasPrefix(c.url, "https://")) {
			seen[c.url] = true
			out = append(out, c.url)
		}
	}
	if len(out) > 10 {
		out = out[:10]
	}
	return out
}

func sniffImage(data []byte) string {
	switch {
	case bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")):
		return "png"
	case bytes.HasPrefix(data, []byte{0xff, 0xd8, 0xff}):
		return "jpeg"
	case bytes.HasPrefix(data, []byte("GIF87a")), bytes.HasPrefix(data, []byte("GIF89a")):
		return "gif"
	case len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP":
		return "webp"
	case bytes.HasPrefix(data, []byte{0, 0, 1, 0}):
		return "ico"
	}
	head := data
	if len(head) > 4096 {
		head = head[:4096]
	}
	head = bytes.ToLower(bytes.TrimLeft(head, "\xef\xbb\xbf \t\r\n"))
	if bytes.Contains(head, []byte("<svg")) && !bytes.Contains(head, []byte("<html")) {
		return "svg"
	}
	return ""
}

// magickRun always names the coder from the sniffed bytes, so ImageMagick never
// guesses a format from the content of a downloaded file.
func magickRun(tool string, args ...string) (string, bool) {
	argv := []string{}
	if tool != "" {
		argv = append(argv, tool)
	}
	argv = append(argv, "-limit", "memory", "256MiB", "-limit", "time", "10")
	argv = append(argv, args...)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "magick", argv...).Output()
	return string(out), err == nil
}

// toIcon writes data as an icon file in tmp and returns its path and size in pixels.
func toIcon(data []byte, tmp, name string) (string, int) {
	kind := sniffImage(data)
	if kind == "" {
		return "", 0
	}
	if kind == "svg" {
		path := filepath.Join(tmp, name+".svg")
		if os.WriteFile(path, data, 0o644) != nil {
			return "", 0
		}
		return path, 512
	}
	src := filepath.Join(tmp, name+".src")
	if os.WriteFile(src, data, 0o644) != nil {
		return "", 0
	}
	info, ok := magickRun("identify", "-format", "%w %h\n", kind+":"+src)
	if !ok {
		return "", 0
	}
	// An .ico holds several sizes; take the largest.
	bestIdx, bestArea, size := -1, -1, 0
	for i, line := range strings.Split(strings.TrimSpace(info), "\n") {
		var w, h int
		if n, _ := fmt.Sscanf(line, "%d %d", &w, &h); n != 2 {
			return "", 0
		}
		if w*h > bestArea {
			bestIdx, bestArea, size = i, w*h, min(w, h)
		}
	}
	if bestIdx < 0 {
		return "", 0
	}
	out := filepath.Join(tmp, name+".png")
	dim := fmt.Sprintf("%dx%d>", iconSize, iconSize)
	if _, ok := magickRun("", fmt.Sprintf("%s:%s[%d]", kind, src, bestIdx), "-background", "none", "-resize", dim, "PNG32:"+out); !ok {
		return "", 0
	}
	return out, size
}

func findIcon(target, host, tmp string) string {
	deadline := time.Now().Add(iconBudget)
	bestPath, bestSize := "", 0
	for n, u := range iconCandidates(target, deadline) {
		data, _ := fetch(u, iconMax, deadline)
		if data == nil {
			continue
		}
		if path, size := toIcon(data, tmp, strconv.Itoa(n)); path != "" && size >= minSize && size > bestSize {
			bestPath, bestSize = path, size
			if size >= goodSize {
				break
			}
		}
	}
	if bestPath == "" {
		if data, _ := fetch("https://icons.duckduckgo.com/ip3/"+host+".ico", iconMax, deadline); data != nil {
			if path, size := toIcon(data, tmp, "ddg"); path != "" && size >= minSize {
				bestPath = path
			}
		}
	}
	return bestPath
}

// userIcon reads an icon the user gave. Returns its path, or "" and why not.
func userIcon(raw, tmp string) (string, string) {
	raw = strings.TrimPrefix(strings.TrimSpace(raw), "file://")
	var data []byte
	if httpRe.MatchString(raw) {
		data, _ = fetch(raw, iconMax, time.Now().Add(iconBudget))
		if data == nil {
			return "", "Couldn't download that link"
		}
	} else {
		path := raw
		if path == "~" || strings.HasPrefix(path, "~/") {
			path = homeDir() + path[1:]
		}
		if !filepath.IsAbs(path) {
			return "", "Use a full path, like ~/Pictures/icon.png"
		}
		fi, err := os.Stat(path)
		if err != nil || fi.IsDir() {
			return "", "No readable file at that path"
		}
		if fi.Size() > iconMax {
			return "", "That file is over 5 MB"
		}
		if data, err = os.ReadFile(path); err != nil {
			return "", "No readable file at that path"
		}
	}
	if path, _ := toIcon(data, tmp, "user"); path != "" {
		return path, ""
	}
	return "", "That isn't a PNG, JPEG, WebP, GIF, ICO or SVG image"
}

func moveFile(from, to string) error {
	data, err := os.ReadFile(from)
	if err != nil {
		return err
	}
	return os.WriteFile(to, data, 0o644)
}

func cmdWebapp(args []string) {
	name := strings.TrimSpace(ctrlRe.ReplaceAllString(args[0], ""))
	if name == "" {
		sayStatus("bad-name", nil)
		return
	}
	target, host := normalizeURL(args[1])
	if target == "" {
		sayStatus("bad-url", nil)
		return
	}
	id := webAppID(name, host)
	entry := webAppsDir() + "/" + id + ".desktop"
	if _, err := os.Stat(entry); err == nil {
		sayStatus("exists", map[string]any{"name": name})
		return
	}
	tmp, err := os.MkdirTemp("", "graphite-webapp-")
	if err != nil {
		sayStatus("failed", nil)
		return
	}
	defer os.RemoveAll(tmp)
	var found string
	if len(args) > 2 && strings.TrimSpace(args[2]) != "" {
		var why string
		if found, why = userIcon(args[2], tmp); found == "" {
			sayStatus("bad-icon", map[string]any{"message": why})
			return
		}
	} else if found = findIcon(target, host, tmp); found == "" {
		sayStatus("no-icon", map[string]any{"host": host})
		return
	}
	os.MkdirAll(webIconsDir(), 0o755)
	os.MkdirAll(webAppsDir(), 0o755)
	icon := webIconsDir() + "/" + id + filepath.Ext(found)
	if moveFile(found, icon) != nil {
		sayStatus("failed", nil)
		return
	}
	text := fmt.Sprintf("[Desktop Entry]\nType=Application\nName=%s\nComment=Web app · %s\nExec=%s \"--app=%s\"\nIcon=%s\nTerminal=false\nCategories=Network;\nKeywords=webapp;\n",
		strings.ReplaceAll(name, `\`, `\\`), host, webAppBrowser, strings.ReplaceAll(target, "%", "%%"), icon)
	if writeAtomic(entry, []byte(text)) != nil {
		sayStatus("failed", nil)
		return
	}
	sayStatus("ok", map[string]any{"id": id, "name": name, "url": target, "icon": icon})
}

// webAppEntry returns a web app's desktop file; it refuses anything but our own files.
func webAppEntry(id string) string {
	if !webIDRe.MatchString(id) {
		return ""
	}
	path := webAppsDir() + "/" + id + ".desktop"
	if fi, err := os.Stat(path); err != nil || fi.IsDir() {
		return ""
	}
	return path
}

func entryValue(path, key string) string {
	raw, _ := os.ReadFile(path)
	if m := regexp.MustCompile(`(?m)^` + key + `=(.*)$`).FindSubmatch(raw); m != nil {
		return string(m[1])
	}
	return ""
}

func editEntry(path, key, value string) {
	raw, _ := os.ReadFile(path)
	re := regexp.MustCompile(`(?m)^` + key + `=.*$`)
	done := false
	writeAtomic(path, re.ReplaceAllFunc(raw, func(m []byte) []byte {
		if done {
			return m
		}
		done = true
		return []byte(key + "=" + value)
	}))
}

func cmdWebappRename(id, nameIn string) {
	entry := webAppEntry(id)
	name := strings.TrimSpace(ctrlRe.ReplaceAllString(nameIn, ""))
	if entry == "" {
		sayStatus("missing", nil)
	} else if name == "" {
		sayStatus("bad-name", nil)
	} else {
		editEntry(entry, "Name", strings.ReplaceAll(name, `\`, `\\`))
		sayStatus("ok", nil)
	}
}

func cmdWebappIcon(id, raw string) {
	entry := webAppEntry(id)
	if entry == "" {
		sayStatus("missing", nil)
		return
	}
	tmp, err := os.MkdirTemp("", "graphite-webapp-")
	if err != nil {
		sayStatus("failed", nil)
		return
	}
	defer os.RemoveAll(tmp)
	found, why := userIcon(raw, tmp)
	if found == "" {
		sayStatus("bad-icon", map[string]any{"message": why})
		return
	}
	os.MkdirAll(webIconsDir(), 0o755)
	icon := webIconsDir() + "/" + id + filepath.Ext(found)
	old := entryValue(entry, "Icon")
	if moveFile(found, icon) != nil {
		sayStatus("failed", nil)
		return
	}
	if old != icon && strings.HasPrefix(old, webIconsDir()+"/") {
		os.Remove(old)
	}
	editEntry(entry, "Icon", icon)
	sayStatus("ok", nil)
}

func cmdWebappDelete(id string) {
	entry := webAppEntry(id)
	if entry == "" {
		sayStatus("missing", nil)
		return
	}
	icon := entryValue(entry, "Icon")
	os.Remove(entry)
	if strings.HasPrefix(icon, webIconsDir()+"/") {
		os.Remove(icon)
	}
	sayStatus("ok", nil)
}
