#!/usr/bin/env bash

#set -e
#set -x

# 兼容mac和linux
sed(){
    if [[ "$(uname)" == "Darwin" ]]; then
        gsed "$@"
    else
        sed "$@"
    fi
}


if [[ ! -z "$1" ]]; then
    file="$1"
    #echo $file
else
    echo "target file should be provided"
    exit 1
fi

IMAGE_FOLDER=$(dirname $file)/$(basename -s .md $file)

if [[ ! -e "$IMAGE_FOLDER" ]]; then
    mkdir -p "$IMAGE_FOLDER"
fi


declare -A urls
# 提取图片链接
for i in $(cat "$file" | grep '!\[.*\](http.*)') ; do
    #echo "$cnt: $i"
    url="$(echo "$i" | sed 's/!\[.*\]//g;s/[()]//g;')"
    alt="$(echo "$i" | sed 's/(.*)//g;s/!\[//g;s/\]//g;')"
    echo "$alt -> $url"
    #urls["$url"]="$alt"
    urls["$alt"]="$url"
done

for i in ${!urls[*]} ; do
    url="${urls[$i]}"
    alt="$i"
    echo "$url -> $alt"
    # 下载图片，使用图片标题命名
    wget -c -O "$IMAGE_FOLDER/$alt"  "$url"
    #sed "s/$i/$IMAGE_FOLDER\/${urls[$i]}/g;" $file
    # 修改markdown中的图片链接为本地图片路径
    sed -i "s/!\[$alt\](.*)/!\[$alt\](\/$alt)/g" "$file"
done

