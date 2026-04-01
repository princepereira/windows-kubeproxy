ARG WINDOWS_VERSION=ltsc2022
FROM mcr.microsoft.com/windows/servercore:${WINDOWS_VERSION}

WORKDIR /kubeproxy

COPY windows-kubeproxy.exe .

ENTRYPOINT ["windows-kubeproxy.exe"]
