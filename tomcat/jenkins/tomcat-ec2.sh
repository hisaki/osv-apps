#!/bin/sh
#
#  Copyright (C) 2013 Cloudius Systems, Ltd.
#
#  This work is open source software, licensed under the terms of the
#  BSD license as described in the LICENSE file in the top-level directory.
#

SRC_ROOT=$1
AWS_REGION=$2
AWS_ZONE=$3
AWS_PLACEMENT_GROUP="$4"

SCRIPTS_ROOT="`pwd`/scripts"

. $SCRIPTS_ROOT/ec2-utils.sh

post_test_cleanup() {
 if test x"$TEST_INSTANCE_ID" != x""; then
    stop_instance_forcibly $TEST_INSTANCE_ID
    wait_for_instance_shutdown $TEST_INSTANCE_ID
    delete_instance $TEST_INSTANCE_ID
 fi
}

handle_test_error() {
 echo "=== Error occured. Cleaning up. ==="
 post_test_cleanup
 exit 1
}

prepare_instance_for_test() {
 local TEST_OSV_VER=`$SCRIPTS_ROOT/osv-version.sh`-jenkins-perf-ec2-`timestamp`
 local TEST_INSTANCE_NAME=OSv-$TEST_OSV_VER

 echo "=== Create OSv instance ==="
 $SCRIPTS_ROOT/release-ec2.sh --instance-only \
                              --override-version $TEST_OSV_VER \
                              --region $AWS_REGION \
                              --zone $AWS_ZONE \
                              --placement-group $AWS_PLACEMENT_GROUP || handle_test_error

 TEST_INSTANCE_ID=`get_instance_id_by_name $TEST_INSTANCE_NAME`

 if test x"$TEST_INSTANCE_ID" = x""; then
  handle_test_error
 fi

 change_instance_type $TEST_INSTANCE_ID cc2.8xlarge || handle_test_error
 start_instances $TEST_INSTANCE_ID || handle_test_error
 wait_for_instance_startup $TEST_INSTANCE_ID 300 || handle_test_error

 TEST_INSTANCE_IP=`get_instance_private_ip $TEST_INSTANCE_ID`

 if test x"$TEST_INSTANCE_IP" = x""; then
  handle_test_error
 fi
}

echo "=== Build everything ==="
( cd $SRC_ROOT && \
  rm -rf wrk && git clone https://github.com/cloudius-systems/wrk.git && \
  cd wrk && \
  make -j `nproc` ) || handle_test_error

make -j `nproc` image=tomcat-benchmark img_format=raw || handle_test_error

prepare_instance_for_test

ping -c 4 $TEST_INSTANCE_IP

echo "=== Warmup ==="
$SRC_ROOT/wrk/wrk -t4 -c16 -d5m http://$TEST_INSTANCE_IP:8081/servlet/json || handle_test_error

echo "=== Main test ==="
WRK_OUT_FILE=wrk.out
echo "Output goes to $WRK_OUT_FILE"
$SRC_ROOT/wrk/wrk --latency -t4 -c128 -d5m http://$TEST_INSTANCE_IP:8081/servlet/json | tee $WRK_OUT_FILE

python3 apps/tomcat/jenkins/tomcat-xml.py -o tomcat-perf.xml -m tps $WRK_OUT_FILE || handle_test_error

echo "=== Cleaning up ==="
post_test_cleanup
exit 0
