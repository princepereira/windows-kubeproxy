package main

import (
	"os"

	"k8s.io/component-base/cli"
	proxyapp "k8s.io/kubernetes/cmd/kube-proxy/app"
)

func main() {
	command := proxyapp.NewProxyCommand()
	os.Exit(cli.Run(command))
}
