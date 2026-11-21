// Installed alongside act's runner package when building XcodeRunnerKit's native runner.
package runner

import (
	"context"
	"encoding/json"
	"regexp"

	"fmt"
	"github.com/nektos/act/pkg/model"
	"gopkg.in/yaml.v3"
	"strings"

	"github.com/nektos/act/pkg/workflowpattern"
)

// GitHub schedules push and pull_request workflows by ref before assigning any job.
func (rc *RunContext) checkWorkflowRef(ctx context.Context) error {
	if rc.caller != nil {
		return nil
	}
	gh := rc.getGithubContext(ctx)
	event, ok := rc.Run.Workflow.OnEvent(gh.EventName).(map[string]interface{})
	if !ok {
		return nil
	}
	ref, kind, other := gh.Ref, "branches", "tags"
	switch gh.EventName {
	case "pull_request", "pull_request_target":
		ref = gh.BaseRef
	case "push":
		if strings.HasPrefix(ref, "refs/tags/") {
			kind, other, ref = "tags", "branches", strings.TrimPrefix(ref, "refs/tags/")
		} else {
			ref = strings.TrimPrefix(ref, "refs/heads/")
		}
	default:
		return nil
	}
	rejection := fmt.Errorf("workflow %s does not select %s %q for %s", rc.Run.Workflow.File, kind, ref, gh.EventName)
	if event[kind] == nil && event[kind+"-ignore"] == nil && (event[other] != nil || event[other+"-ignore"] != nil) {
		return rejection
	}
	for _, key := range []string{kind, kind + "-ignore"} {
		if event[key] == nil {
			continue
		}
		entries, ok := event[key].([]interface{})
		if !ok {
			return fmt.Errorf("expected a list of patterns for %s", key)
		}
		match := false
		for _, entry := range entries {
			pattern, err := workflowpattern.CompilePattern(fmt.Sprint(entry))
			if err != nil {
				return err
			}
			if pattern.Regex.MatchString(ref) {
				match = !pattern.Negative
			}
		}
		if (key == kind) != match {
			return rejection
		}
	}
	return nil
}

// Expression evaluation rewrites YAML nodes. A job's runs-on node is shared by its matrix entries.
func copyWorkflowNode(node yaml.Node) yaml.Node {
	children := node.Content
	node.Content = nil
	for _, child := range children {
		value := copyWorkflowNode(*child)
		node.Content = append(node.Content, &value)
	}
	return node
}

var needsContext = regexp.MustCompile(`(?i)\bneeds\b`)

// Upstream job outputs become available only during execution.
func routingNeedsOutputs(job *model.Job) bool {
	var referencesNeeds func(*yaml.Node) bool
	referencesNeeds = func(node *yaml.Node) bool {
		if needsContext.MatchString(node.Value) {
			return true
		}
		for _, child := range node.Content {
			if referencesNeeds(child) {
				return true
			}
		}
		return false
	}
	return needsContext.MatchString(job.If.Value) || referencesNeeds(&job.RawRunsOn) ||
		(job.Strategy != nil && referencesNeeds(&job.Strategy.RawMatrix))
}

func (rc *RunContext) workflowJobID() string {
	if rc.caller == nil {
		return rc.Run.JobID
	}
	parent := rc.caller.runContext
	key := parent.workflowJobID()
	if len(parent.Matrix) != 0 {
		matrix, _ := json.Marshal(parent.Matrix)
		key += string(matrix)
	}
	return key + "/" + rc.Run.JobID
}
