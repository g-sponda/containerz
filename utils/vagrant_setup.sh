#!/bin/bash

# Install Zig and libc6-dev which is needed for our containerz to work fine
# since we are using a header from C
sudo snap install zig --beta --classic
sudo apt install libc6-dev -y

script_dir=$(dirname "$(realpath "$0")")
source "$script_dir/create_generic_fs.sh"
