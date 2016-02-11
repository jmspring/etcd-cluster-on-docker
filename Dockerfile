FROM        alpine:3.2
RUN         apk add --update bash ca-certificates openssl tar drill net-tools netcat-openbsd && \
            wget https://github.com/coreos/etcd/releases/download/v2.2.5/etcd-v2.2.5-linux-amd64.tar.gz && \
            tar xzvf etcd-v2.2.5-linux-amd64.tar.gz && \
            mv etcd-v2.2.5-linux-amd64/etcd* /bin/ && \
            apk del --purge tar openssl && \
            rm -Rf etcd-v2.2.5-linux-amd64* /var/cache/apk/*
EXPOSE      2379 2380 4001 7001
ADD         /bin/etcd_init.sh /bin/etcd_init.sh
RUN         chmod +x /bin/etcd_init.sh
CMD         ["/bin/etcd_init.sh"]            