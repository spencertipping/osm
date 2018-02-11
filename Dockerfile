FROM gentoo-local

ADD ni osm-docker-script /usr/bin/

CMD osm-docker-script /data
