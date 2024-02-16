#!/bin/bash

for i in ./* ; do
    echo $i;
    perlcritic --profile ./perlcriticrc $i || exit 1
done;
