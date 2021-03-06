#!/usr/bin/env bash

#PYTHON_CMD=python3.5

(( $DEBUG == 1 )) && set -x

function install {

    # Get the default version of python enabled
    VER=`python -V 2>&1`
    VER=`echo $VER | cut -d " " -f 2`
    # Uninstall 3.6 and install a specific version of 3.6 if already installed
    if [[ "$VER" =~ 3.6 ]]; then
       dnf remove -y rs-epel-release
       dnf remove -y python36 python36-devel 
       dnf install -y https://centos8.iuscommunity.org/ius-release.rpm
       dnf install -y python36u python36u-libs python36u-devel python36u-pip
    elif [[ "$VER" =~ 3 ]]; then
       dnf remove -y rs-epel-release
       dnf remove -y python3* python3*-libs python3*-devel python3*-pip
       dnf install -y https://centos8.iuscommunity.org/ius-release.rpm
       dnf install -y python36u python36u-libs python36u-devel python36u-pip
    elif [[ "$VER" =~ 2.7 ]]; then
        dnf install -y https://centos8.iuscommunity.org/ius-release.rpm
        dnf install -y python36u python36u-libs python36u-devel python36u-pip
    fi

   # Install dependencies for dSIPRouter
    dnf install -y dnf-utils
    dnf --setopt=group_package_types=mandatory,default,optional groupinstall -y "Development Tools"
    dnf install -y firewalld nginx
    dnf install -y python36 python36-devel 
    dnf install -y logrotate rsyslog perl libev-devel util-linux

    # create dsiprouter user and group
    # sometimes locks aren't properly removed (this seems to happen often on VM's)
    rm -f /etc/passwd.lock /etc/shadow.lock /etc/group.lock /etc/gshadow.lock
    useradd --system --user-group --shell /bin/false --comment "dSIPRouter SIP Provider Platform" dsiprouter

    # Reset python cmd in case it was just installed
    setPythonCmd

    # Fix for bug: https://bugzilla.redhat.com/show_bug.cgi?id=1575845
    if (( $? != 0 )); then
        systemctl restart dbus
        systemctl restart firewalld
    fi

    # Setup Firewall for DSIP_PORT
    firewall-offline-cmd --zone=public --add-port=${DSIP_PORT}/tcp

    # Enable and start firewalld if not already running
    systemctl enable firewalld
    systemctl restart firewalld

    PIP_CMD="pip"
    cat ${DSIP_PROJECT_DIR}/gui/requirements.txt | xargs -n 1 $PYTHON_CMD -m ${PIP_CMD} install
    if [ $? -eq 1 ]; then
        echo "dSIPRouter install failed: Couldn't install required libraries"
        exit 1
    fi

    # Configure rsyslog defaults
    if ! grep -q 'dSIPRouter rsyslog.conf' /etc/rsyslog.conf 2>/dev/null; then
        cp -f ${DSIP_PROJECT_DIR}/resources/syslog/rsyslog.conf /etc/rsyslog.conf
    fi

    # Setup dSIPRouter Logging
    cp -f ${DSIP_PROJECT_DIR}/resources/syslog/dsiprouter.conf /etc/rsyslog.d/dsiprouter.conf
    touch /var/log/dsiprouter.log
    systemctl restart rsyslog

    # Setup logrotate
    cp -f ${DSIP_PROJECT_DIR}/resources/logrotate/dsiprouter /etc/logrotate.d/dsiprouter

    # Install dSIPRouter as a service
    perl -p -e "s|^(ExecStart\=).+?([ \t].*)|\1$PYTHON_CMD\2|;" \
        -e "s|'DSIP_RUN_DIR\=.*'|'DSIP_RUN_DIR=$DSIP_RUN_DIR'|;" \
        -e "s|'DSIP_PROJECT_DIR\=.*'|'DSIP_PROJECT_DIR=$DSIP_PROJECT_DIR'|;" \
        ${DSIP_PROJECT_DIR}/dsiprouter/dsiprouter.service > /etc/systemd/system/dsiprouter.service
    chmod 0644 /etc/systemd/system/dsiprouter.service
    systemctl daemon-reload
    systemctl enable dsiprouter
}


function uninstall {
    # Uninstall dependencies for dSIPRouter
    PIP_CMD="pip"

    cat ${DSIP_PROJECT_DIR}/gui/requirements.txt | xargs -n 1 $PYTHON_CMD -m ${PIP_CMD} uninstall --yes
    if [ $? -eq 1 ]; then
        echo "dSIPRouter uninstall failed or the libraries are already uninstalled"
        exit 1
    else
        echo "DSIPRouter uninstall was successful"
        exit 0
    fi

    dnf remove -y python36u\*
    dnf remove -y ius-release
    dnf groupremove -y "Development Tools"

    # Remove the repos
    rm -f /etc/yum.repos.d/ius*
    rm -f /etc/pki/rpm-gpg/IUS-COMMUNITY-GPG-KEY
    yum clean all

    # Remove Firewall for DSIP_PORT
    firewall-cmd --zone=public --remove-port=${DSIP_PORT}/tcp --permanent
    firewall-cmd --reload

    # Remove dSIPRouter Logging
    rm -f /etc/rsyslog.d/dsiprouter.conf

    # Remove logrotate settings
    rm -f /etc/logrotate.d/dsiprouter

    # Remove dSIProuter as a service
    systemctl disable dsiprouter.service
    rm -f /etc/systemd/system/dsiprouter.service
    systemctl daemon-reload
}


case "$1" in
    uninstall|remove)
        uninstall
        ;;
    install)
        install
        ;;
    *)
        echo "usage $0 [install | uninstall]"
        ;;
esac

