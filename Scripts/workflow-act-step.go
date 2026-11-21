//go:build darwin

package container

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// A native step may launch xcode-runner, which must receive TERM to release its own
// build process group and Simulator. Wait for the step group before releasing the slot.
func runNativeStep(ctx context.Context, cmd *exec.Cmd) error {
	cmd.Cancel = func() error {
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	cmd.WaitDelay = 8 * time.Second
	err := cmd.Run()
	if cmd.Process == nil || ctx.Err() == nil {
		return err
	}
	group := -cmd.Process.Pid
	if syscall.Kill(group, syscall.SIGTERM) == nil {
		deadline := time.Now().Add(8 * time.Second)
		for syscall.Kill(group, 0) == nil {
			if time.Now().After(deadline) {
				syscall.Kill(group, syscall.SIGKILL)
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	return err
}
