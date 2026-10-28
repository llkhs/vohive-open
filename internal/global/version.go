package global

import (
	"runtime/debug"
	"strings"
)

var (
	// Version 应用程序版本，由编译时 -ldflags -X 注入
	Version = "dev"

	// GitCommit Git 提交哈希，由编译时 -ldflags -X 注入
	GitCommit = ""

	// BuildTime 构建时间，由编译时 -ldflags -X 注入
	BuildTime = "Unknown"
)

func init() {
	if GitCommit == "" {
		if info, ok := debug.ReadBuildInfo(); ok {
			for _, setting := range info.Settings {
				if setting.Key == "vcs.revision" {
					GitCommit = setting.Value
					break
				}
			}
		}
	}
}

// ShortGitCommit 返回最多 7 位的短提交哈希
func ShortGitCommit() string {
	commit := strings.TrimSpace(GitCommit)
	if len(commit) > 7 {
		return commit[:7]
	}
	return commit
}

// DisplayVersion 返回规范化的版本显示字符串，包含版本号与版本哈希
func DisplayVersion() string {
	ver := strings.TrimSpace(Version)
	if ver == "" {
		ver = "dev"
	}
	short := ShortGitCommit()
	if short != "" && !strings.Contains(ver, short) {
		return ver + " (" + short + ")"
	}
	return ver
}
