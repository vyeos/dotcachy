package main

// Images to suggest for a web app icon.
//
//	graphite images   JSON list of images to suggest, newest first

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

var imageExts = []string{"png", "svg", "jpg", "jpeg", "webp", "gif", "ico"}

const imagesMax = 1500

type imageRow struct {
	Path string `json:"path"`
	Size int64  `json:"size"`
}

func cmdImages() {
	home := homeDir()
	argv := []string{"fd", "--no-ignore", "-t", "f", "-S", "-5M", "--max-results", "5000", "--absolute-path", "--base-directory", home}
	for _, e := range imageExts {
		argv = append(argv, "-e", e)
	}
	for _, name := range fileSkip {
		argv = append(argv, "-E", name)
	}
	// Hidden folders are skipped, except the icons other web apps already use.
	argv = append(argv, ".", home, webIconsDir())
	type found struct {
		row imageRow
		mod time.Time
	}
	seen := map[string]bool{}
	var all []found
	for _, p := range strings.Split(output(5*time.Second, argv...), "\n") {
		if p == "" || seen[p] {
			continue
		}
		seen[p] = true
		if fi, err := os.Stat(p); err == nil {
			all = append(all, found{imageRow{p, fi.Size()}, fi.ModTime()})
		}
	}
	sort.Slice(all, func(i, j int) bool { return all[i].mod.After(all[j].mod) })
	rows := []imageRow{}
	for i := 0; i < len(all) && i < imagesMax; i++ {
		rows = append(rows, all[i].row)
	}
	fmt.Println(jsonText(rows))
}
