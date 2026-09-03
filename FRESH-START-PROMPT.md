# Prompt for installing and validating a fresh OCUDU CUDU deployment

Copy everything below into a new session.

---

我已將OCUDU-setup repository clone到這台機器。主要目標是使用repository內的
安裝工具，在這台主機完成OCUDU CUDU安裝、站點設定、image build、服務啟動與連線
驗收，讓部署完成後可以持續連接既有5GC及實體O-RU。這不是針對repository本身進行
軟體開發或單元測試的任務；下列檢查是確認安裝與連線正確的部署驗收手段，不是對
repository做測試的最終目的。

先找出同時包含`FRESH-START-PROMPT.md`、`Dockerfile`、`compose.yaml`與`config/`的
repository目錄，將其絕對路徑記為 `PROJECT_DIR`，後續工具呼叫都以它作為workdir，
不可假設固定home路徑，也不可誤用其他OCUDU source或舊部署目錄。

請實際完成安裝、設定、build與啟動，不要只提供指令或只做靜態檢查。部署最低成功
標準是CU-CP、CU-UP與DU皆為running，E1及F1連線建立，而且明確看到F1 Setup成功；
只有安裝檔案存在、image build成功或CU連上5GC，都不算完整部署完成。

部署與驗收目標：

1. 以剛clone的repository為起點；repository本身不應包含`config/site.env`或generated
   configs。先以唯讀方式盤點主機上既有OCUDU containers與`ocudu/split-ofh:26.04`
   image。若已存在，不得只為模擬fresh test而刪除、停止或覆寫；先確認其所屬部署，
   再詢問使用者要沿用、遷移或另做乾淨安裝。
2. 使用 `./cudu.sh init` 建立站點設定。
3. 先核對主機實際NIC、IP、CPU、PHC，由LLM自行填入可可靠偵測的config值。
4. 對無法從主機可靠判定的5GC、O-RU、VLAN、MAC及RF值，詢問使用者要沿用
   本prompt的目前預設值，或只提供需要修改的欄位。
5. 執行setup、render、build、environment check及CU-CP/CU-UP啟動，驗證E1、
   N2 SCTP、NG Setup與AMF/PLMN。
6. 通過實體O-RU安全checkpoint後啟動OFH DU，驗證F1 SCTP與F1 Setup。
7. 記錄每一步安裝指令、結果與任何阻礙部署的腳本問題。不要為了程式碼整理而重構；
   若確認repository腳本有實際缺陷，做完成部署所需的最小修正，並重新執行受影響的
   安裝或驗收步驟。

權限處理規則：

1. 先使用目前session可用的權限完成操作；若產品提供approval或escalation機制，
   應先使用該機制，不要立刻要求使用者代跑。
2. 執行Docker操作前先檢查 `docker info`；若失敗，再檢查
   `sudo -n docker info`。執行其他root操作前先檢查 `sudo -n true`。
3. 如果session已有所需權限，LLM應自行完成全部部署與驗收操作，不要要求使用者代跑。
4. 如果sudo要求密碼：
   - 不可詢問、接收、顯示或儲存使用者密碼。
   - 不可修改sudoers、Docker socket權限或將使用者加入docker群組。
   - 不要反覆嘗試sudo或尋找繞過密碼的方法。
   - 將狀態標記為 `WAITING_FOR_USER`，不要標記成 `BLOCKED`。
   - 輸出一個可直接複製的完整command block，必須包含正確的 `cd` 路徑、
     所需sudo命令，以及輸出exit status的命令。
   - 停在該checkpoint並等待使用者回覆完整輸出，不要跳過該步驟。
5. 使用者表示命令已完成後，LLM必須以唯讀檢查驗證post-condition，
   再繼續後續步驟，不可只依賴口頭確認。
6. 只有使用者拒絕執行、命令持續失敗，或缺少必要硬體/外部條件時，
   才將該項目標記為 `BLOCKED`。

需要人工輸入sudo密碼時，使用以下格式，不要只回報權限不足：

```text
需要你的sudo密碼才能繼續。請在自己的terminal執行：

cd "<填入實際PROJECT_DIR絕對路徑>"
sudo ./setup.sh
printf 'setup_exit=%s\n' "$?"

完成後請回覆完整輸出。我會先驗證setup結果，再繼續render、check、build、啟動與連線驗收。
```

Config填寫與詢問規則：

1. `./cudu.sh init` 後，LLM要直接讀取並編輯 `config/site.env`，不可把整份
   config丟給使用者手動填寫。
2. 以下資料應優先由LLM使用唯讀命令自行偵測並填入：
   - N2/N3 interface、parent interface、VLAN ID、local CIDR/IP。
   - fronthaul NIC是否存在、carrier、速度、MAC、hardware timestamp與PHC。
   - CPU型號、online CPU、可用cpuset與目前hugepages。
   - Docker/Compose/linuxptp工具及既有container/image狀態。
3. 不可只靠主機可靠偵測的資料包括AMF/UPF位址、PLMN/TAC/SST、RU management
   IP、RU/DU logical MAC、OFH VLAN/eAxC、PTP role/domain及radio profile。
   LLM先列出下方目前預設值，然後只詢問一次：

   `除必須另行確認的RU_MGMT_ADDR外，是否全部沿用目前prompt預設的5GC、O-RU、external PTP與RF值？若否，請只列出要修改的欄位與新值。`

4. `RU_MGMT_ADDR`沒有安全預設值：external GM模式下，它必須是fronthaul網段內
   尚未使用的host CIDR，而且不可等於 `RU_IP`或`GM_IP`。LLM應先檢查現有位址與
   address conflict；若仍無法判定，必須單獨詢問使用者，不能沿用外部GM使用的
   `192.168.2.100/24`。
5. 若使用者回答沿用預設，LLM應自行把其他預設值寫入config，不要逐欄追問。
   若使用者提供變更，只修改指定欄位，並自動維持CIDR/IP、VLAN與profile欄位一致。
6. 若自動偵測值與prompt預設不同，先顯示差異並詢問，不可靜默改用另一張NIC、
   另一個PHC、不同CPU或不同網段。
7. 寫入後要顯示不含secret的config摘要，取得使用者確認再執行會改變host的setup。

目前預期的5GC與主機資料如下，請先用唯讀命令核對；若現況不同先告訴我，
不要自行猜值：

```text
AMF IP/port:        192.168.19.175:38412
UPF IP:             192.168.24.175
N2 interface:       enp6s0
N2 local CIDR/IP:   192.168.22.155/24, 192.168.22.155
N3 interface:       vlan1016
N3 parent/VLAN ID:  enp6s0 / 1016
N3 local CIDR/IP:   192.168.24.155/24, 192.168.24.155
PLMN/TAC/SST:       00101 / 1 / 1
```

目前O-RU與Open Fronthaul資料如下：

```text
O-RU model:         Pegatron PR1400-78I (R1220-078L / SGF)
Fronthaul NIC:      enp4s0f0
RU management IP:  192.168.2.1
Host RU CIDR:       必須確認未使用位址；不可等於RU或GM IP
External GM IP:    192.168.2.100（既有RU設定，使用前確認）
RU MAC:             e8:c7:cf:a1:1e:e2
DU logical MAC:     00:02:01:1a:73:d4
C/U-plane VLAN:     906 / 906
OFH MTU:            1500
PTP role/domain:    external-gm / 24
```

目前radio profile先保持不變：

```text
Band/ARFCN:         n78 / 631020
Bandwidth/SCS:      90 MHz / 30 kHz
Antennas:           4T4R
PCI:                1
PRACH eAxC:         4,5,6,7
DL/UL eAxC:         0,1,2,3
Compression:        static BFP 9-bit
```

目前i7-12700 CPU配置先保持：

```text
DU cpuset:          3-11,15
main pool:          3,8-11,15
RU workers:         4-5
OFH TX/RX:          6
OFH timing:         7
OFH IRQ/misc IRQ:   2 / 12
hugepages:          1024 x 2 MiB
```

請依以下順序進行：

```bash
cd "$PROJECT_DIR"
sed -n '1,240p' README.md
./cudu.sh init
```

接著檢查 `config/site.env` 是否完整包含上述資料。使用 `ip -br link`、
`ip -br addr`、`ip route`、`ethtool -T enp4s0f0`、`lscpu` 驗證主機。
注意：fronthaul目前可能沒有carrier，但NIC必須存在且具有hardware raw clock；
沒有接RU時，不要因no-carrier而改用其他NIC。CU階段可在no-carrier時完成，但DU階段
必須等待指定fronthaul NIC具備穩定10-Gbps carrier；不可關閉link check來繞過。

確認後執行：

```bash
sudo ./setup.sh
./cudu.sh render
sudo ./cudu.sh check
sudo ./cudu.sh build
sudo ./cudu.sh up
sudo ./cudu.sh status
sudo docker logs ocudu-cu-cp --tail 150
sudo docker logs ocudu-cu-up --tail 150
```

CU階段驗證事項：

- 所有generated YAML可解析且沒有未展開的 `${...}`。
- DU base config的 `cell_cfg.enabled` 必須是 `false`。
- Compose預設第一階段只啟動CU-CP與CU-UP。
- build使用 `config/site.env` 中固定的 `OCUDU_REF`。
- CU containers為running，設定mount指向 `config/generated/`。
- `docker logs` 必須能直接看到CU應用日誌，不可依賴停止container才flush的檔案。
- CU logs不應再出現 `Couldn't register stdin handler`；若仍出現，保留證據但先確認
  NG Setup、E1與程序狀態，再判斷是否致命。
- CU-CP log需檢查NG Setup/AMF連線結果；失敗時保留完整錯誤與網路證據。

CU階段全部通過後，繼續完成DU-CU連線，不可在只有CU成功時結束。先載入config
供唯讀檢查使用：

```bash
cd "$PROJECT_DIR"
set -a
source config/site.env
set +a
ip -br link show "$FH_IF"
ethtool "$FH_IF"
ethtool -T "$FH_IF"
sudo ./check-cudu-ofh-gates.sh || true
```

進入DU階段前，LLM必須提出一個合併確認問題，讓使用者確認或提供變更：

```text
要繼續實體OFH DU部署與F1 Setup驗收，請確認：
1. 是否沿用目前90-MHz/4T4R、VLAN 906與既有eAxC設定？
2. O-RU是否已套用相同profile，且radio及每個PA均為disabled/off？
3. external telecom GM IP/domain為何，host ptp4l是否已為SLAVE，RU是否已lock？
4. RF測試環境、頻譜授權、屏蔽或衰減條件是否已確認？
若任一項不同，請只提供需要修改的值或目前未完成的條件。
```

不可只依賴口頭確認radio狀態。若LLM已有O-RU CLI權限，應自行執行並保存
`show radio frontend`、`show ptp clock`與`show s-plane status`證據；若SSH需要密碼，
不可索取密碼，改為輸出完整command block請使用者執行並回覆輸出。無法確認
radio/PA disabled時，狀態為 `WAITING_FOR_USER`，不得啟動active-cell DU。

安全條件與10-Gbps carrier具備後，依序執行：

```bash
cd "$PROJECT_DIR"
sudo ./setup-ofh-performance.sh
sudo ./check-cudu-ofh-gates.sh
sudo env RF_ENVIRONMENT_CONFIRMED=1 \
  RU_RADIO_DISABLED_CONFIRMED=1 \
  RU_PTP_LOCK_CONFIRMED=1 \
  ./cudu.sh pre-rf
sudo ./cudu.sh status
```

`PTP_ROLE=external-gm`是唯一預設流程。LLM必須驗證外部GM、host ptp4l SLAVE、
domain及RU lock。不得進入或執行`optional/temp-gm/`；該目錄不屬於本次CUDU流程。

`pre-rf`會以明確CLI override啟用cell以建立served-cell list，但O-RU radio/PA必須
繼續disabled/off。不得把generated base YAML的 `cell_cfg.enabled: false` 改成true。

DU-CU成功標準必須全部滿足：

- `ocudu-cu-cp`、`ocudu-cu-up`及`ocudu-du-ofh`皆為running且restart count為0。
- host network namespace內F1-C SCTP port 38472為 `ESTAB`。
- CU-CP與DU證據中可確認 `F1 Setup: Procedure completed successfully`，不能只因
  container為running就判定成功。
- E1仍為established、N2 SCTP仍為established，NG Setup沒有因DU啟動而中斷。
- RU radio/PA狀態在DU啟動後再次確認仍為disabled/off。
- 不得執行 `ue-attach`、不得開啟RU radio/PA、不得進行OTA或UE registration。

至少執行以下驗證；若應用file log尚未flush，以live SCTP狀態和CU Docker stdout
為主要證據，不可為了flush而先停CU-CP：

```bash
sudo docker compose --env-file config/site.env --profile ofh ps
sudo ss -H -n -A sctp state established
sudo docker logs ocudu-cu-cp --tail 250
sudo docker logs ocudu-cu-up --tail 250
sudo docker logs ocudu-du-ofh --tail 250
sudo tail -n 250 logs/du-ofh.log 2>/dev/null || true
```

若DU/F1失敗，保持RU radio/PA disabled，收集container inspect、exit code、完整log、
carrier、PTP與SCTP證據。停止DU並恢復host-global調校，不可用關閉gate、改MAC/VLAN、
啟用radio或隱藏warning來取得假成功：

```bash
sudo docker compose --env-file config/site.env --profile ofh stop du
sudo ./restore-ofh-performance.sh
```

若全部成功，依使用者本次要求保留CU與DU running，但在最終報告明確註記external
GM/PTP lock證據、host-global performance tuning仍在作用、RU radio/PA必須持續
disabled/off，並提供上述停止與restore命令。

請在最後提供部署驗收pass/fail表格、發現的腳本問題、修改的檔案，以及其他使用者
clone這個repository後可重複執行的最短完整CUDU安裝指令。只有CU-CP、CU-UP與DU
running且E1/F1 Setup成功，才可宣告OCUDU已正確安裝、設定並完成5GC與O-RU連線；
除非我另行明確授權，O-RU radio/PA必須保持disabled/off。

---
