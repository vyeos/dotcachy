package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func homeDir() string {
	home, _ := os.UserHomeDir()
	return home
}

func configDir() string {
	if v := os.Getenv("XDG_CONFIG_HOME"); v != "" {
		return v
	}
	return homeDir() + "/.config"
}

// sayStatus prints the one JSON reply the panel reads from report-style commands.
func sayStatus(status string, fields map[string]any) {
	if fields == nil {
		fields = map[string]any{}
	}
	fields["status"] = status
	fmt.Println(jsonText(fields))
}

// jsonText encodes v without the HTML escaping Go adds by default.
func jsonText(v any) string {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.Encode(v)
	return string(bytes.TrimRight(b.Bytes(), "\n"))
}

// output returns stdout of argv, or "" when it fails or runs out of time.
func output(timeout time.Duration, argv ...string) string {
	return string(outputBytes(timeout, nil, argv...))
}

func outputBytes(timeout time.Duration, stdin []byte, argv ...string) []byte {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	return out
}

func loadJSON(path string, into any) bool {
	raw, err := os.ReadFile(path)
	return err == nil && json.Unmarshal(raw, into) == nil
}

func writeAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".graphite-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	tmp.Close()
	os.Chmod(tmp.Name(), 0o644)
	return os.Rename(tmp.Name(), path)
}
