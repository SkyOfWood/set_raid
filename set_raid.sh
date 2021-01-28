#!/bin/bash
#Author: wuchenglin
Version='2020-10-30'

echo_INFO(){
    echo -e "    $1"
}

mkdir -p /tmp/raid && cd /tmp/raid
URL='https://raw.githubusercontent.com/SkyOfWood/set_raid/master'
if [[ -f raid_ctrl_x64.tar.gz ]];then
    if [[ `md5sum raid_ctrl_x64.tar.gz |awk '{print$1}'` != `curl -sk $URL/md5sum.txt` ]];then
        curl -skO $URL/raid_ctrl_x64.tar.gz && tar zxf raid_ctrl_x64.tar.gz
    else
        tar zxf raid_ctrl_x64.tar.gz
    fi
else
    curl -skO $URL/raid_ctrl_x64.tar.gz && tar zxf raid_ctrl_x64.tar.gz
fi

test -f /sbin/lspci || yum install -y -q pciutils
DISK_CON_MODEL=`lspci |grep -E "SAS|LSI"|awk -F: '{print$3}'`
if [[ -z $(echo_INFO "$DISK_CON_MODEL"|grep -i raid) ]];then
    echo_INFO "该磁盘控制器不支持硬RAID"
    echo_INFO "当前控制器型号为:$DISK_CON_MODEL"
    exit 2
fi

if [[ `dmidecode -s system-manufacturer` =~ "Dell" ]];then
    RaidCMD="sudo /tmp/raid/perccli64"
else
    RaidCMD="sudo /tmp/raid/storcli64"
fi
# $RaidCMD /call show all > raid_all.conf
$RaidCMD /call show all J > raid_all.conf.json
$RaidCMD /call /vall show all J > raid_vd_all.json
$RaidCMD /call /eall /sall show J > raid_pd.json

get_ctrl_num(){
    CTRL_COUNT=$(expr `$RaidCMD show ctrlcount|grep 'Controller Count'|awk -F= '{print$2}'` - 1)
    seq 0 $CTRL_COUNT
}
VD_Num=$(expr `ABC=$(./jq -r ".\"Controllers\"[].\"Response Data\".\"Virtual Drives\"" raid_all.conf.json);echo $ABC|sed 's/ / + /g'|xargs expr` - 1)

get_bootdrive(){
    for c in `get_ctrl_num`;do
        BootDrive_C=$($RaidCMD /call show bootdrive J|./jq -r ".Controllers[${c}].\"Response Data\".\"Controller Properties\"[0].Value")
        if [[ $BootDrive_C =~ "No Boot Drive" ]];then
            # conf_bootdrive
            echo_INFO "当前raid卡未指定启动盘"
            exit 2
        fi
        BootDrive_VD=$($RaidCMD /call show bootdrive J|./jq -r ".\"Controllers\"[${c}].\"Response Data\".\"Controller Properties\"[0].Value" |awk -F: '{print$2}')
        BootCtrl="${c}"
        break
    done
}

get_disk_type(){
    BootDrive_ES=$($RaidCMD /call /v$BootDrive_VD show all J|./jq -r ".\"Controllers\"[0].\"Response Data\".\"PDs for VD ${BootDrive_VD}\"[].\"EID:Slt\"")
    PD_Num=$(expr `ABC=$(./jq -r ".\"Controllers\"[].\"Response Data\".\"Physical Drives\"" raid_all.conf.json);echo $ABC|sed 's/ / + /g'|xargs expr` - 1)
    DISK_TYPE=`./jq -r ".\"Controllers\"[].\"Response Data\".\"Drive Information\"[].\"Med\"" raid_pd.json`
    for c in `get_ctrl_num`;do
        HDD_FILE="c$c.HDD_DISK"
        SSD_FILE="c$c.SSD_DISK"
        rm -f $HDD_FILE && touch $HDD_FILE
        rm -f $SSD_FILE && touch $SSD_FILE
        if [[ ${c} != $BootCtrl ]];then
            BootDrive_ES="null"
        fi
        for i in `seq 0 $PD_Num`; do
            if [[ $(./jq -r ".\"Controllers\"[${c}].\"Response Data\".\"Drive Information\"[${i}].\"Med\"" raid_pd.json) =~ "HDD" ]];then
                ./jq -r ".\"Controllers\"[${c}].\"Response Data\".\"Drive Information\"[${i}].\"EID:Slt\"" raid_pd.json|egrep -v -w $(echo $BootDrive_ES|sed 's/ /|/g') >> $HDD_FILE
            elif [[ $(./jq -r ".\"Controllers\"[${c}].\"Response Data\".\"Drive Information\"[${i}].\"Med\"" raid_pd.json) =~ "SSD" ]];then
                ./jq -r ".\"Controllers\"[${c}].\"Response Data\".\"Drive Information\"[${i}].\"EID:Slt\"" raid_pd.json|egrep -v -w $(echo $BootDrive_ES|sed 's/ /|/g') >> $SSD_FILE
            fi
        done
    done
}

show_conf(){
    echo_INFO ""
    echo -e "-- RAID Level Supported --"
    ./jq -r ".\"Controllers\"[].\"Response Data\".\"Capabilities\".\"RAID Level Supported\"" raid_all.conf.json
    echo_INFO ""
    ./get_raid_info.py
    echo_INFO ""
}

locate_disk(){
    Drive_Letter=$1
    ACTION=$2
    if [[ $Drive_Letter =~ "sd" ]];then
        SCSI_ID=$(ls -l /dev/disk/by-id/scsi-*|grep -v part| awk '{print$9,$11}'|sed 's:/dev/disk/by-id/scsi-3::g'|sed 's:../../::g'|grep $Drive_Letter|awk '{print$1}')
        for c in `get_ctrl_num`;do
            for i in `seq 0 $VD_Num`; do
                if [[ $(./jq -r ".\"Controllers\"[${c}].\"Response Data\".\"VD${i} Properties\".\"SCSI NAA Id\"" raid_vd_all.json) =~ "$SCSI_ID" ]];then
                    E_S=$(./jq -r ".\"Controllers\"[].\"Response Data\".\"PDs for VD ${i}\"[].\"EID:Slt\"" raid_vd_all.json|sed 's/:/\/s/g'|sed 's/^/\/e/g')
                    C_E_S="/c$c$E_S"
                    if [[ $ACTION == "start" ]];then
                        echo_INFO "\n正在使 $Drive_Letter [$C_E_S] 插槽灯bu~ling~bu~ling~的闪烁"
                        $RaidCMD $C_E_S start locate |grep -E "Status|Description"
                    elif [[ $ACTION == "stop" ]];then
                        echo_INFO "\n正在停止 $Drive_Letter [$C_E_S] 插槽灯闪烁"
                        $RaidCMD $C_E_S stop locate |grep -E "Status|Description"
                    else
                        echo_INFO "请输入正确的动作"
                    fi
                    break
                fi
            done
            break
        done
    else
        echo_INFO "请输入正确的盘符"
    fi
    echo_INFO ""
}

deal_boot(){
    PATH_SCSI='/tmp/raid/path_scsi.file'
    echo 'DEVNAME   ID_SERIAL_SHORT' > $PATH_SCSI
    for i in $(ls -l /dev/sd[a-z]|awk '{print$NF}');do
        . <(udevadm info --export --query=property --name=$i)
        echo -e "$DEVNAME $ID_SERIAL_SHORT" >> $PATH_SCSI
    done
    RAID_BOOT=$($RaidCMD /call show bootdrive J|./jq -r ".Controllers[].\"Response Data\".\"Controller Properties\"[].\"Value\"" |awk -F: '{print$2}')
    ROOT_SCSI_ID=`udevadm info --name=$(lsblk --output MOUNTPOINT,PKNAME|grep -w /|awk '{print$2}') --query=property|grep ID_SERIAL_SHORT|awk -F= '{print$2}'`
    for c in `get_ctrl_num`;do
        for i in `seq 0 $VD_Num`; do
            if [[ $(./jq -r ".\"Controllers\"[${c}].\"Response Data\".\"VD${i} Properties\".\"SCSI NAA Id\"" raid_vd_all.json) == "$ROOT_SCSI_ID" ]];then
                echo -e "Controllers_VD: /c${c}/v${i}" >> $PATH_SCSI
                break
            fi
        done
        break
    done
    REAL_ROOT_SCSI_ID=$(./jq -r ".\"Controllers\"[].\"Response Data\".\"VD${RAID_BOOT} Properties\".\"SCSI NAA Id\"" raid_vd_all.json)
    for c in `get_ctrl_num`;do
        for i in `seq 0 $VD_Num`; do
            if [[ $(./jq -r ".\"Controllers\"[${c}].\"Response Data\".\"VD${i} Properties\".\"SCSI NAA Id\"" raid_vd_all.json) == "$REAL_ROOT_SCSI_ID" ]];then
                echo -e "REAL_ROOT_SCSI_ID: /c${c}/v${i}" >> $PATH_SCSI
                break
            fi
        done
        break
    done
    if [[ "$1" == "show" ]];then
        echo_INFO "当前的启动盘为："
        echo_INFO "    系统盘符：$(fgrep $ROOT_SCSI_ID $PATH_SCSI |awk '{print$1}')"
        echo_INFO "    盘符RAID路径：$(fgrep -w Controllers_VD $PATH_SCSI |awk '{print$2}')"
        echo_INFO "实际生效的配置："
        echo_INFO "    系统盘符：$(fgrep $REAL_ROOT_SCSI_ID $PATH_SCSI |awk '{print$1}')"
        echo_INFO "    盘符RAID路径：$(fgrep -w REAL_ROOT_SCSI_ID $PATH_SCSI |awk '{print$2}')"
        echo_INFO "RAID卡配置Virtual Drive：$RAID_BOOT"
    elif [[ "$1" == "set" ]];then
        if [[ $2 == "auto" ]];then
            for c in `get_ctrl_num`;do
                for i in `seq 0 $VD_Num`; do
                    if [[ $(./jq -r ".\"Controllers\"[${c}].\"Response Data\".\"VD${i} Properties\".\"SCSI NAA Id\"" raid_vd_all.json) =~ "$ROOT_SCSI_ID" ]];then
                        $RaidCMD /c${c} /v${i} set bootdrive=on
                        break
                    fi
                done
                break
            done
        else
            SCSI_ID=$(fgrep $2 $PATH_SCSI|awk '{print$2}')
            for c in `get_ctrl_num`;do
                for i in `seq 0 $VD_Num`; do
                    if [[ -n `./jq -r ".\"Controllers\"[${c}].\"Response Data\".\"VD${i} Properties\"|select (.\"SCSI NAA Id\" == \"$SCSI_ID\")" raid_vd_all.json` ]];then
                        BOOT_C_V_ID="/c${c}/v${i}"
                        break
                    fi
                done
                break
            done
            $RaidCMD $BOOT_C_V_ID set bootdrive=on
        fi
    else
        echo_INFO "请输入正确的参数"
    fi
}

delete_raid(){
    # 根据业务类型来判断服务器当前是否还存在业务流量
    # echo_INFO "正在判断系统流量..."
    # FLOW_IN=$(./ifstat 2 3 |awk 'NR>=3{print}'|awk -vOFS= '{for(i=1;i<=NF;i+=2)$(i+1)=FS}1'|awk '{for(i=1;i<=NF;i++){array[i]+=$i}}END{for(i in array){ave=array[i]/NR;print ave}}'|awk 'BEGIN {max = 0} {if ($1+0 > max+0) max=$1} END {print max}'|xargs echo | awk '{print int($0)}')
    # if [[ "$FLOW_IN" -gt 1000 ]];then
    #     echo_INFO "流量大于1000KB，无法删除RAID配置"
    #     exit 2
    # fi
    deal_boot set auto
    VDS=$(for i in `seq 0 $VD_Num`;do ./jq -r ".\"Controllers\"[0].\"Response Data\".\"VD LIST\"[${i}].\"DG/VD\"" raid_all.conf.json;done |awk -F/ '{print$2}'|egrep -v -w $BootDrive_VD)
    if [[ -z $VDS ]];then
        echo_INFO "当前除了系统盘，没有可删除的VD \n"
        exit 0
    fi
    echo_INFO "正在删除VD: `echo -e $VDS` \n" #此处有输出BUG
    for c in `get_ctrl_num`;do
        for v in $VDS;do
            if [[ $c != $BootCtrl ]];then
                $RaidCMD /c$c /vall del force      
            fi
            $RaidCMD /c$c /v$v del force
        done
    done
}

create_raid_all(){
    RAID_TYPE="$1"
    echo_INFO "正在配置所有同类型磁盘合并成一个RAID$RAID_TYPE\n"
    get_disk_type
    for c in `get_ctrl_num`;do
        HDD_FILE="c$c.HDD_DISK"
        SSD_FILE="c$c.SSD_DISK"
        ALL_HDD=`cat $HDD_FILE|tr "\n" ","|sed 's/,$//g'`
        ALL_SSD=`cat $SSD_FILE|tr "\n" ","|sed 's/,$//g'`
        if [[ -s $HDD_FILE ]];then
            echo_INFO "Controller: $c 的 HDD正在合并成一个RAID$RAID_TYPE，E:S=$ALL_HDD"
            $RaidCMD /c${c} add vd r$RAID_TYPE size=all drive=$ALL_HDD |grep -E "Status|Description"
        fi
        if [[ -s $SSD_FILE ]];then
            echo_INFO "Controller: $c 的 SSD正在合并成一个RAID$RAID_TYPE，E:S=$ALL_SSD"
            $RaidCMD /c${c} add vd r$RAID_TYPE size=all drive=$ALL_SSD |grep -E "Status|Description"
        fi
    done
}

create_raidx0_all(){
    RAID_TYPE="$1"
    MIX_DISK="$2"
    echo_INFO "正在配置所有同类型磁盘合并成一个RAID$RAID_TYPE\n"
    get_disk_type
    for c in `get_ctrl_num`;do
        HDD_FILE="c$c.HDD_DISK"
        SSD_FILE="c$c.SSD_DISK"
        HDD_COUNT=$(wc -l $HDD_FILE|awk '{print$1}')
        HDD_REMAINDER=$(expr `expr $(wc -l $HDD_FILE|awk '{print$1}') - $MIX_DISK` % 2)
        SSD_COUNT=$(wc -l $SSD_FILE|awk '{print$1}')
        SSD_REMAINDER=$(expr `expr $(wc -l $SSD_FILE|awk '{print$1}') - $MIX_DISK` % 2)
        ALL_HDD=$(head -n`expr $HDD_COUNT - $HDD_REMAINDER` $HDD_FILE|tr "\n" ","|sed 's/,$//g')
        ALL_SSD=$(head -n`expr $SSD_COUNT - $SSD_REMAINDER` $SSD_FILE|tr "\n" ","|sed 's/,$//g')
        HDD_Array=$(expr $(head -n`expr $HDD_COUNT - $HDD_REMAINDER` $HDD_FILE|wc -l) / 2)
        SSD_Array=$(expr $(head -n`expr $SSD_COUNT - $SSD_REMAINDER` $SSD_FILE|wc -l) / 2)
        if [[ $HDD_COUNT -ge $MIX_DISK ]];then
            echo_INFO "Controller: $c 的 HDD合并成RAID$RAID_TYPE，E:S=$ALL_HDD"
            $RaidCMD /c${c} add vd r$RAID_TYPE size=all drive=$ALL_HDD PDperArray=$HDD_Array |grep -E "Status|Description"
            if [[ $HDD_REMAINDER -ne 0 ]];then
                SURPLUS_HDD=$(tail -n$HDD_REMAINDER $HDD_FILE |tr "\n" ","|sed 's/,$//g')
                echo_INFO "当前还有$HDD_REMAINDER块磁盘未加入RAID$RAID_TYPE，E:S=$SURPLUS_HDD"
            fi
        else
            echo_INFO "\n当前HDD磁盘数量不足$MIX_DISK块，无法合成RAID$RAID_TYPE，当前数量为：$HDD_COUNT，E:S=$ALL_HDD"
        fi
        if [[ $SSD_COUNT -ge $MIX_DISK ]];then
            echo_INFO "Controller: $c 的 SSD合并成RAID$RAID_TYPE，E:S=$ALL_SSD"
            $RaidCMD /c${c} add vd r$RAID_TYPE size=all drive=$ALL_SSD PDperArray=$SSD_Array|grep -E "Status|Description"
            if [[ $SSD_REMAINDER -ne 0 ]];then
                SURPLUS_SSD=$(tail -n$SSD_REMAINDER $SSD_FILE |tr "\n" ","|sed 's/,$//g')
                echo_INFO "当前还有$SSD_REMAINDER块磁盘未加入RAID$RAID_TYPE，E:S=$SURPLUS_SSD"
            fi
        else
            echo_INFO "\n当前SSD磁盘数量不足$MIX_DISK块，无法合成RAID$RAID_TYPE，当前数量为：$SSD_COUNT，E:S=$ALL_SSD"
        fi
    done
}

create_raid_customize(){
    RAID_TYPE="$1"
    RAID_Drive=$2
    for c in `get_ctrl_num`;do
        echo_INFO "Controller: $c 的 $RAID_Drive 正在合并成一个RAID$RAID_TYPE"
        $RaidCMD /c${c} add vd r$RAID_TYPE size=all drive=$RAID_Drive |grep -E "Status|Description"
    done
}

create_raid0(){
    if [[ $1 == "each" ]];then
        echo_INFO "正在配置所有磁盘单盘RAID0\n"
        $RaidCMD /call add vd each r0
        $RaidCMD /call/vall set wrcache=AWB rdcache=RA iopolicy=Cached
    elif [[ $1 == "all" ]];then
        create_raid_all 0
    else
        create_raid_customize 0 $1
    fi
}

create_raid1(){
    if [[ $1 == "all" ]];then
        create_raid_all 1
    else
        create_raid_customize 1 $1
    fi
}

create_raid5(){
    if [[ $1 == "all" ]];then
        create_raid_all 5
    else
        create_raid_customize 5 $1
    fi
}

create_raid10(){
    if [[ $1 == "all" ]];then
        create_raidx0_all 10 4
    else
        create_raid_customize 10 $1
    fi
}

create_raid50(){
    if [[ $1 == "all" ]];then
        create_raidx0_all 50 6
    else
        create_raid_customize 50 $1
    fi
}

command_customize(){
    $RaidCMD "$@"
}

help_raid(){
    echo_INFO ""
    echo_INFO "Version: set_raid $Version"
    echo_INFO "Author : chenglin.wu@baishancloud.com"
    echo_INFO "Thanks : gandalf@NOSPAM.le-vert.net && vincent@NOSPAM.cojot.name \n"
    echo_INFO "[WARNING] 无法跨磁盘控制器或磁盘类型做RAID，当前控制器数量为:`get_ctrl_num|wc -l`"
    echo_INFO "RAID绑定磁盘数量说明:"
    echo_INFO "RAID0 最小1，且为1的倍数，最大32， 空间利用率100% (个别型号控制器需要两张磁盘)"
    echo_INFO "RAID1 最小2，且为2的倍数，最大2，  空间利用率50%"
    echo_INFO "RAID5 最小3，且为1的倍数，最大32， 空间利用率(N-1)/N*100%"
    echo_INFO "RAID10最小4，且为2的倍数，最大256，空间利用率50%"
    echo_INFO "RAID50最小6，且为2的倍数，最大32， 空间利用率(N-1)/N*50% \n"
    echo_INFO "-s|--show      查看当前的配置"
    echo_INFO "-l|--locate    硬盘定位"
    echo_INFO "               -l sdb start 打开背板磁盘插槽灯闪烁"
    echo_INFO "               -l sdb stop  关闭背板磁盘插槽灯闪烁"
    echo_INFO "-b|--boot      查看和设置raid启动盘"
    echo_INFO "               -b show 查看当前启动盘"
    echo_INFO "               -b set auto 自动配置启动盘(执行完后请认真检查)"
    echo_INFO "               -b set /dev/sdb 设置sdb为启动盘"
    echo_INFO "-d|--delete    删除现有的RAID配置"
    echo_INFO "-c|--create    创建一个raid"
    echo_INFO "               -c raid0 each 未配置的物理盘做成单盘RAID0"
    echo_INFO "               -c raid0 all  所有同类型物理盘合并成一个大容量RAID0"
    echo_INFO "               -c raid0 \"32:1,32:2,...,32:n\" 自定义磁盘做RAID0"
    echo_INFO "               ---"
    echo_INFO "               -c raid1 all  所有同类型物理盘合并成一个大容量RAID1"
    echo_INFO "               -c raid1 \"32:1,32:2,...,32:n\" 自定义磁盘做RAID1"
    echo_INFO "               ---"
    echo_INFO "               RAID5,RAID10,RAID50操作方法同RAID1，且无each参数"
    echo_INFO "-m|--cmd       运行自定义命令"
    echo_INFO "               -m 'help'查看帮助"
    echo_INFO "-h|--help      查看帮助"
    echo_INFO ""
}

ARGS=`getopt -a -o sl:b:dc:m:h -l show,locate,boot,delete,create:,cmd,help,debug $3 -- "$@"`
[ $? -ne 0 ]
eval set -- "${ARGS}"
while true;do
    case "$1" in
    -s|--show)
        show_conf; break;;
    -l|--locate)
        locate_disk $2 $3
        break;;
    -b|--boot)
        deal_boot $2 $3; break;;
    -d|--delete)
        get_bootdrive
        delete_raid; break;;
    -c|--create)
        get_bootdrive
        if [[ $2 == "raid0" ]];then
            create_raid0 $3
        fi
        if [[ $2 == "raid1" ]];then
            create_raid1 $3
        fi
        if [[ $2 == "raid5" ]];then
            create_raid5 $3
        fi
        if [[ $2 == "raid10" ]];then
            create_raid10 $3
        fi
        if [[ $2 == "raid50" ]];then
            create_raid50 $3
        fi
        break;;
    -m|--cmd)
        command_customize $3; break;;
    -h|--help)
        help_raid; break;;
    --debug)
        deal_boot $3; break;;
    # --)
    #     help_raid; break;;
    esac
shift
done
