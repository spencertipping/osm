FROM ubuntu:16.04

RUN apt-get -y update
RUN apt-get -qqy install curl libsys-mmap-perl pbzip2 liblz4-tool

ADD ni osm-docker-script /usr/bin/

CMD osm-docker-script /data
