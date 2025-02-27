#!/bin/bash

# Set source and destination
SRC="/"
DEST="/home/containerz"
DEST_FS="$DEST/genericfs"

# Create essential directories
sudo mkdir -p "$DEST_FS"/{dev,proc,sys,etc,bin,sbin,lib,lib64,usr,var,home,root,tmp}

# Copy files and directories, excluding system dirs
sudo rsync -avx --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","$DEST"} "$SRC" "$DEST_FS"

sudo chown -R $USER: "$DEST"
