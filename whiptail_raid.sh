#!/bin/bash

test -f /usr/sbin/lspci || yum install -y -q pciutils
DISK_CON_MODEL=`lspci |grep -E "SAS|LSI"|awk -F: '{print$3}'`
if [[ -z $(echo "$DISK_CON_MODEL"|grep -i raid) ]];then
    echo "该磁盘控制器不支持RAID"
    echo "当前控制器型号为:$DISK_CON_MODEL"
    exit 2
fi

if [[ `dmidecode -s system-manufacturer` =~ "Dell" ]];then
    test -f /opt/MegaRAID/perccli/perccli64 || yum install -y -q perccli
    RaidCMD="sudo /opt/MegaRAID/perccli/perccli64"
else
    test -f /opt/MegaRAID/storcli/storcli64 || yum install -y -q storcli
    RaidCMD="sudo /opt/MegaRAID/storcli/storcli64"
fi

mkdir -p /tmp/raid && cd /tmp/raid
$RaidCMD /call show all J > raid_all.conf.json
$RaidCMD /call /vall show all J > raid_vd_all.json
$RaidCMD /call /eall /sall show all J > raid_pd_all.json

CTRL_Num=$(expr `$RaidCMD show ctrlcount J|jq -r ".Controllers[].\"Response Data\".\"Controller Count\""` - 1)
VD_Num=$(expr `jq -r ".\"Controllers\"[].\"Response Data\".\"Virtual Drives\"" raid_all.conf.json` - 1)

raid_type(){
    jq -r ".\"Controllers\"[].\"Response Data\".\"/c${c}/v${i}\"[].\"TYPE\"" raid_vd_all.json
}

disk_path(){
    jq -r ".\"Controllers\"[].\"Response Data\".\"VD${i} Properties\".\"SCSI NAA Id\"" raid_vd_all.json|xargs -i sh -c 'ls -l /dev/disk/by-id/*{}'|grep scsi|awk -F/ '{print$NF}'
}

disk_size(){
    jq -r ".\"Controllers\"[].\"Response Data\".\"/c${c}/v${i}\"[].\"Size\"" raid_vd_all.json|sed 's/ //g'
}

e_slot(){
    jq -r ".\"Controllers\"[].\"Response Data\".\"PDs for VD ${i}\"[].\"EID:Slt\"" raid_vd_all.json|sed ":a;N;s/\n/,/g;ta"
}

show(){
    echo -e "RAID卡型号：\n$(lspci |grep SAS|awk -F: '{print$3}'|sed 's/^ //g')"
    echo '---'
    echo -e "支持的RAID类型：\n$(jq -r ".\"Controllers\"[].\"Response Data\".\"Capabilities\".\"RAID Level Supported\"" raid_all.conf.json)"
    echo '---'
    echo '虚拟硬盘(VD)配置：'
    for c in `seq 0 $CTRL_Num`;do
        for i in `seq 0 $VD_Num`;do
            printf "VD:%-3s 类型:%-5s 盘符:%-5s 大小:%-10s 物理硬盘:[%-10s]\n" $i `raid_type` `disk_path` `disk_size` `e_slot`;
            printf ""
        done
    done
    echo '---'
    echo '物理硬盘(PD)列表'
    for c in `seq 0 $CTRL_Num`;do
        /opt/MegaRAID/perccli/perccli64 /call show all J|jq -r ".\"Controllers\"[].\"Response Data\".\"PD LIST\""
    done
    echo '---'
}
show > show.list

locate(){
    path_slot(){
    for c in `seq 0 $CTRL_Num`;do
        for i in `seq 0 $VD_Num`;do
            echo -e "$(disk_path) VD:$i|PD:[$(e_slot)] OFF"
        done
    done
    }
    DISTROS=$(whiptail --title "磁盘定位" --checklist \
    "请使用空格键选择需要点亮的磁盘" 20 60 10 \
    `path_slot` 3>&1 1>&2 2>&3)
    
    exitstatus=$?
    if [ $exitstatus = 0 ]; then
        echo "Your favorite distros are:" $DISTROS
    else
        main
    fi
}

main(){
    DISTROS=$(whiptail --title "白山RAID配置管理程序" --backtitle "chenglin.wu@baishan.com" --radiolist \
    "请使用空格键选择你要执行的操作" 20 60 7 \
    "show" "查看当前的配置" ON \
    "locate" "硬盘定位（打开/关闭背板硬盘插槽灯闪烁）" OFF \
    "boot" "查看和设置raid启动盘" OFF \
    "delete" "删除现有的RAID配置" OFF \
    "create" "创建一个RAID" OFF \
    "cmd" "运行自定义命令" OFF \
    "help" "查看帮助" OFF 3>&1 1>&2 2>&3)

    exitstatus=$?
    if [ $exitstatus = 0 ]; then
        if [[ $DISTROS == "show" ]];then
            if (whiptail --title "当前RAID信息" --textbox show.list --ok-button "返回到主菜单" 30 70) then
                main
            fi
        elif [[ $DISTROS == "locate" ]];then
            locate
        fi
    else
        echo "You chose Cancel."
    fi
}
main