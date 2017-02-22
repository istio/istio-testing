# Stored at gcr.io/endpoints-jenkins/ubuntu-16-04-slave:latest
FROM ubuntu:xenial

# Please make sure that you update scripts/linux-install-software as well.
ENV JENKINS_SLAVE_VERSION 2.62
# Bucket used to store already built binaries
ARG TOOLS_BUCKET

# Installing necessary packages
RUN rm -rf /var/lib/apt/lists/* \
    && apt-get update --fix-missing -qq \
    && apt-get install -qqy git iptables procps sudo xz-utils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Adding sudo group user no password access.
# This is used by Jenkins user to start docker service
RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# Installing Tools
ADD scripts /tmp/esp_tmp/scripts
RUN chmod +x /tmp/esp_tmp/scripts/linux-install-software
RUN /tmp/esp_tmp/scripts/linux-install-software \
      -b "${TOOLS_BUCKET}" \
    && rm -rf /tmp/esp_tmp

ENV PATH /usr/lib/google-cloud-sdk/bin:${PATH}

# Setting up jnlp
ENV HOME /home/jenkins

RUN useradd -c "Jenkins user" -d ${HOME} -G docker,sudo -m jenkins -s /bin/bash

ADD github_helper /usr/local/bin/github_helper

ADD http://repo.jenkins-ci.org/public/org/jenkins-ci/main/remoting/${JENKINS_SLAVE_VERSION}/remoting-${JENKINS_SLAVE_VERSION}.jar /tmp/slave.jar
RUN mkdir -p /usr/share/jenkins \
    && chmod 755 /usr/share/jenkins \
    && cp /tmp/slave.jar /usr/share/jenkins/slave.jar \
    && chmod 644 /usr/share/jenkins/slave.jar \
    && rm -rf /tmp/slave.jar

ADD docker/slaves/jenkins-slave /usr/local/bin/jenkins-slave
ADD docker/slaves/entrypoint /usr/local/bin/entrypoint
RUN chmod +rx /usr/local/bin/jenkins-slave /usr/local/bin/entrypoint /usr/local/bin/github_helper

USER jenkins
RUN mkdir ${HOME}/.jenkins
VOLUME ${HOME}/.jenkins
WORKDIR ${HOME}

ENTRYPOINT ["entrypoint"]
