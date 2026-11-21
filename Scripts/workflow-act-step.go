//go:build darwin

package container

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// A step owns a process group. xcode-runner handles TERM by stopping its Xcode group.
type nativeStepGroups struct {
	mu         sync.Mutex
	background []int
}

func stopStepGroup(pid int) {
	if syscall.Kill(-pid, syscall.SIGTERM) != nil {
		return
	}
	deadline := time.Now().Add(8 * time.Second)
	for syscall.Kill(-pid, 0) == nil {
		if time.Now().After(deadline) {
			syscall.Kill(-pid, syscall.SIGKILL)
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func (g *nativeStepGroups) stop() {
	g.mu.Lock()
	pids := g.background
	g.background = nil
	g.mu.Unlock()
	for _, pid := range pids {
		stopStepGroup(pid)
	}
}

func (g *nativeStepGroups) run(ctx context.Context, cmd *exec.Cmd) error {
	cmd.Cancel = func() error {
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	cmd.WaitDelay = 8 * time.Second
	err := cmd.Run()
	if cmd.Process == nil {
		return err
	}
	pid := cmd.Process.Pid
	if ctx.Err() != nil {
		stopStepGroup(pid)
	} else if syscall.Kill(-pid, 0) == nil {
		// Services can span steps. Stop them when the job closes its environment.
		g.mu.Lock()
		g.background = append(g.background, pid)
		g.mu.Unlock()
	}
	if ctx.Err() == nil && errors.Is(err, exec.ErrWaitDelay) && cmd.ProcessState.Success() {
		return nil
	}
	return err
}
