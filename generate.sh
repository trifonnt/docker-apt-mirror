#!/bin/bash

maxstage="$(echo "$1" | sed '/^\(main\|restricted\|universe\|multiverse\)$/b;s/.*//g')"
maxstage="${maxstage:-restricted}"

dryrun="$(echo "$2" | sed '/^echo$/b;s/.*//g')"
cyan="$(tput setaf 6)"
green="$(tput setaf 2)"
bgreen="$(tput bold ; tput setaf 2)"
red="$(tput setaf 1)"
reset="$(tput sgr0)"
wwwpath="/var/www/mirror.local"

version="16.04"
codename="xenial"
#version="14.04"
#codename="trusty"

# Install Docker
###################################

command -v docker || curl https://get.docker.com/ | sh

# Create source file : fastestmirror.list
###################################

cat <<EOF > fastestmirror.list
deb mirror://mirrors.ubuntu.com/mirrors.txt $codename main restricted universe
deb mirror://mirrors.ubuntu.com/mirrors.txt $codename-updates main restricted universe
deb mirror://mirrors.ubuntu.com/mirrors.txt $codename-backports main restricted universe
deb mirror://mirrors.ubuntu.com/mirrors.txt $codename-security main restricted universe
EOF

# Create source file : mirror.list-[version]
###################################

cat <<EOF > mirror.list-$version
set base_path      /mirrors
set run_postmirror 0
set nthreads       20
set _tilde         0


#deb http://ubuntu-archive.mirrors.d3soft.biz/ubuntu/ $codename
deb http://archive.ubuntu.com/ubuntu/ $codename-updates
deb http://archive.ubuntu.com/ubuntu/ $codename-updates
deb http://archive.ubuntu.com/ubuntu/ $codename-backports
deb http://archive.ubuntu.com/ubuntu/ $codename-security

clean http://archive.ubuntu.com/ubuntu/
EOF

# Create source file : nginx config
###################################

cat <<EOF > nginx.site-available.mirror-local
server {
	listen 80;
	server_name mirror.local;

	location / {
		root $wwwpath;
		autoindex on;
	}
}
EOF

# Create source file : Dockerfile
##################################

cat <<EOF > Dockerfile
FROM ubuntu:$version

MAINTAINER Trifon Trifonov <trifont@gmail.com>

# Some mirrors don't have the required packages for mirror
# So we keep the default one
#ADD fastestmirror.list /etc/apt/sources.list
ADD mirror.list-$codename-main /etc/apt/mirror.list
ADD nginx.site-available.mirror-local /etc/nginx/sites-available/mirror.local

RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Options::=--force-confold install apt-mirror nginx
RUN mkdir -p $wwwpath
RUN mkdir -p /mirrors
RUN apt-mirror
RUN ln -sf /mirrors/mirror/ubuntu-archive.mirrors.d3soft.biz/ubuntu $wwwpath/ubuntu
RUN sed -i '/^daemon/d' /etc/nginx/nginx.conf
RUN sed -i '/^worker_processes/a daemon off;' /etc/nginx/nginx.conf
RUN rm -f /etc/nginx/sites-enabled/default
RUN ln -sf /etc/nginx/sites-available/mirror.local /etc/nginx/sites-enabled/

EXPOSE 80

CMD ["service", "nginx", "start"]
EOF

# Build images : loop from 'main' to $maxstage
###############################################

src_namespace=""
src_imagename="ubuntu:"
src_imagetag="$version"
dst_namespace="trifonnt/"
dst_imagename="apt-mirror:"
for dst_imagetag in main restricted universe multiverse
do
 set -x
  dst_imagerealtag="$codename-$dst_imagetag"
  mkdir -p $dst_imagetag

  src="$src_namespace$src_imagename$src_imagetag"
  dst="$dst_namespace$dst_imagename$dst_imagerealtag"
  echo "${cyan}INFO: Start building '$dst' image from '$src'...${reset}"

  # add nginx config file
  cp nginx.site-available.mirror-local "$dst_imagetag/"

  # update mirror.list content
  sed '/^deb /s/$/ '$dst_imagetag'/' mirror.list-$src_imagetag > mirror.list-$dst_imagerealtag
  cp mirror.list-$dst_imagerealtag "$dst_imagetag/"

  # update mirror.list reference inside Dockerfile
  sed -i '/^ADD mirror.list/s,'$src_imagetag','$dst_imagerealtag',' Dockerfile
  cp Dockerfile "$dst_imagetag/"

  # build
  $dryrun docker build -t $dst $dst_imagetag
  SUCCESS=$?

  if [ $SUCCESS -eq 0 ]; then
    echo "${green}SUCCESS: Build is over for image '$dst'"
  else
    echo "${red}FAILED: An error occured while trying to build image '$dst'. Next build(s) can't proceed. Exiting"
    exit
  fi

  # update Dockerfile for next build
  echo "${reset}"
  sed -i '/^FROM/s,'$src','$dst',' Dockerfile

  src_namespace=$dst_namespace
  src_imagename=$dst_imagename
  src_imagetag=$dst_imagerealtag

  [ "$dst_imagetag" = "$maxstage" ] && break
done

# Helper : script to start latest generated images
###################################################

cat <<EOF > start-local-ubuntu-mirror.sh
docker run -d --name ubuntu-mirror $dst && \
echo "${green}SUCCESS: Container started${reset}" || \
echo "${red}FAILED: An error occured while trying to start the container${reset}"
EOF

if [ $SUCCESS -eq 0 ]; then
  chmod +x start-local-ubuntu-mirror.sh
  $dryrun ./start-local-ubuntu-mirror.sh && \
  echo "
${bgreen}
Congrats !

You now have a fully functional local ubuntu mirror inside a Docker container \\o/
To use it simply start a new container linked to the local ubuntu mirror named \"ubuntu-mirror\"
The link alias **must** be the FQDN target of your deb directives inside the container's sources.list

Example usage (w/ official ubuntu image):
----------------------------------------

    docker run -ti --link ubuntu-mirror:archive.ubuntu.com ubuntu:$version /bin/bash
${reset}
"
fi
