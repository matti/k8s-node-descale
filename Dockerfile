FROM ruby:2.5-alpine3.12

ARG KUBE_VERSION=1.16.2

RUN apk add --no-cache \
    curl bash \
    && curl --fail -Lo /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/v${KUBE_VERSION}/bin/linux/amd64/kubectl \
    && chmod +x /usr/local/bin/kubectl

WORKDIR /build
COPY build .
RUN apk --update add build-base \
    && gem build k8s_node_descale.gemspec \
    && gem install --no-document k8s_node_descale*.gem \
    && apk del build-base \
    && rm -rf /build

WORKDIR /app
COPY app .

USER nobody
ENTRYPOINT [ "/app/entrypoint.sh" ]
