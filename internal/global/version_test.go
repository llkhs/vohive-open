package global

import (
	"testing"
)

func TestDisplayVersion(t *testing.T) {
	origVer := Version
	origCommit := GitCommit
	defer func() {
		Version = origVer
		GitCommit = origCommit
	}()

	Version = "v1.2.3"
	GitCommit = "a90ed18abcdef1234567890"

	if got := ShortGitCommit(); got != "a90ed18" {
		t.Errorf("ShortGitCommit() = %s, want a90ed18", got)
	}

	if got := DisplayVersion(); got != "v1.2.3 (a90ed18)" {
		t.Errorf("DisplayVersion() = %s, want v1.2.3 (a90ed18)", got)
	}

	// 已经包含 commit 时不再重复追加
	Version = "v1.2.3-a90ed18"
	if got := DisplayVersion(); got != "v1.2.3-a90ed18" {
		t.Errorf("DisplayVersion() = %s, want v1.2.3-a90ed18", got)
	}

	// 没有 commit 时直接返回版本
	GitCommit = ""
	Version = "dev"
	if got := DisplayVersion(); got != "dev" {
		t.Errorf("DisplayVersion() = %s, want dev", got)
	}
}
