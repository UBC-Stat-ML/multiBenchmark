#!/bin/bash

EXPECTED_ARGS=1

if [ $# -ne $EXPECTED_ARGS ]
then
  echo "Usage: `basename $0` [blangSDK path]"
  exit 1
fi

cd $1
./setup-cli.sh
cd -
rm -f lib
ln -s $1/build/install/blang/lib .
mkdir -p bin
rm -f bin/blang
cp $1/build/install/blang/bin/blang bin/blang