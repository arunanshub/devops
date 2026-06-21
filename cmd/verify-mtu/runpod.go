package main

import (
	"context"
	"fmt"
	"log/slog"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

type PodSpec struct {
	Name      *string
	Namespace string
	Image     string
	Command   []string
}

func NewPodRunner(
	client *kubernetes.Clientset,
	spec PodSpec,
) defaultPodRunner {
	return defaultPodRunner{podSpec: spec, client: client}
}

type defaultPodRunner struct {
	podSpec PodSpec
	client  *kubernetes.Clientset
}

func (p *defaultPodRunner) Run(ctx context.Context) error {
	slog.InfoContext(ctx, "running")

	_, err := p.createPod(ctx)
	if err != nil {
		return fmt.Errorf("failed to create pod: %w", err)
	}
	defer p.deletePod(ctx)

	return nil
}

func (p *defaultPodRunner) createPod(ctx context.Context) (*corev1.Pod, error) {
	pod, err := p.client.CoreV1().
		Pods(p.podSpec.Namespace).Create(ctx,
		&corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Name:      *p.podSpec.Name,
				Namespace: p.podSpec.Namespace,
			},
			Spec: corev1.PodSpec{
				Containers: []corev1.Container{{
					Name:  *p.podSpec.Name,
					Image: p.podSpec.Image,
					Args:  p.podSpec.Command,
				}},
			},
		}, metav1.CreateOptions{})
	slog.InfoContext(
		ctx,
		"created pod",
		slog.String("name", pod.Name),
	)

	return pod, err
}

func (p *defaultPodRunner) deletePod(ctx context.Context) {
	slog.InfoContext(ctx, "cleaning up pod", slog.String("name", *p.podSpec.Name))
	err := p.client.CoreV1().
		Pods(p.podSpec.Namespace).
		Delete(ctx, *p.podSpec.Name, metav1.DeleteOptions{
			PropagationPolicy: new(metav1.DeletePropagationBackground),
		})
	if err != nil {
		slog.WarnContext(ctx, "failed to delete pod", slog.String("error", err.Error()))
	}
}
