package k8s

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/wait"

	"github.com/arunanshub/devops/internal/logging"
)

// pollInterval is how often pod state is re-checked while waiting.
const pollInterval = 2 * time.Second

// PodSpec describes a short-lived pod created for verification purposes.
type PodSpec struct {
	Name      string
	Namespace string
	Image     string
	Command   []string
	NodeName  string
}

// CreatePod creates a pod from spec. It does not wait for readiness; use
// WaitPodsReady for that.
func (c *Client) CreatePod(ctx context.Context, spec *PodSpec) error {
	pod := &corev1.Pod{
		Name:      spec.Name,
		Namespace: spec.Namespace,
		Spec: corev1.PodSpec{
			NodeName:      spec.NodeName,
			RestartPolicy: corev1.RestartPolicyNever,
			Containers: []corev1.Container{{
				Name:    spec.Name,
				Image:   spec.Image,
				Command: spec.Command,
			}},
		},
	}

	if _, err := c.clientset.CoreV1().
		Pods(spec.Namespace).
		Create(ctx, pod, metav1.CreateOptions{}); err != nil {
		return fmt.Errorf("create pod %s/%s: %w", spec.Namespace, spec.Name, err)
	}

	logging.FromContext(ctx).DebugContext(
		ctx,
		"created pod",
		slog.String("name", spec.Name),
		slog.String("node", spec.NodeName),
	)
	return nil
}

// WaitPodsReady blocks until every named pod reports the Ready condition, or
// the timeout elapses.
func (c *Client) WaitPodsReady(
	ctx context.Context,
	namespace string,
	names []string,
	timeout time.Duration,
) error {
	log := logging.FromContext(ctx)
	log.DebugContext(ctx, "waiting for pods to become ready",
		slog.Any("pods", names), slog.Duration("timeout", timeout))

	for _, name := range names {
		err := wait.PollUntilContextTimeout(ctx, pollInterval, timeout, true,
			func(ctx context.Context) (bool, error) {
				pod, err := c.clientset.CoreV1().Pods(namespace).Get(ctx, name, metav1.GetOptions{})
				if err != nil {
					return false, err
				}
				return isPodReady(pod), nil
			})
		if err != nil {
			return fmt.Errorf("wait for pod %s/%s to become ready: %w", namespace, name, err)
		}
		log.DebugContext(ctx, "pod ready", slog.String("name", name))
	}
	return nil
}

// PodIP returns the pod's IP address.
func (c *Client) PodIP(ctx context.Context, namespace, name string) (string, error) {
	pod, err := c.clientset.CoreV1().Pods(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return "", fmt.Errorf("get pod %s/%s: %w", namespace, name, err)
	}
	if pod.Status.PodIP == "" {
		return "", fmt.Errorf("pod %s/%s has no IP yet", namespace, name)
	}
	return pod.Status.PodIP, nil
}

// DeletePods deletes the named pods, ignoring pods that do not exist. When
// waitGone is true it blocks until every pod is fully removed.
func (c *Client) DeletePods(
	ctx context.Context,
	namespace string,
	names []string,
	waitGone bool,
) error {
	logging.FromContext(ctx).DebugContext(ctx, "deleting pods",
		slog.Any("pods", names), slog.Bool("wait_gone", waitGone))

	propagation := metav1.DeletePropagationBackground
	for _, name := range names {
		err := c.clientset.CoreV1().Pods(namespace).Delete(ctx, name, metav1.DeleteOptions{
			PropagationPolicy: &propagation,
		})
		if err != nil && !apierrors.IsNotFound(err) {
			return fmt.Errorf("delete pod %s/%s: %w", namespace, name, err)
		}
	}

	if !waitGone {
		return nil
	}

	for _, name := range names {
		err := wait.PollUntilContextCancel(ctx, pollInterval, true,
			func(ctx context.Context) (bool, error) {
				_, err := c.clientset.CoreV1().Pods(namespace).Get(ctx, name, metav1.GetOptions{})
				if apierrors.IsNotFound(err) {
					return true, nil
				}
				return false, err
			})
		if err != nil {
			return fmt.Errorf("wait for pod %s/%s to disappear: %w", namespace, name, err)
		}
	}
	return nil
}

func isPodReady(pod *corev1.Pod) bool {
	for _, cond := range pod.Status.Conditions {
		if cond.Type == corev1.PodReady && cond.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}
