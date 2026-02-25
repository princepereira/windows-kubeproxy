package main

import (
	"os"

	"k8s.io/component-base/cli"
	proxyapp "github.com/windows-kubeproxy/cmd/app"
)

func main() {
	command := proxyapp.NewProxyCommand()
	os.Exit(cli.Run(command))
}
