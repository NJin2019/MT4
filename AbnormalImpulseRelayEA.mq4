//+------------------------------------------------------------------+
//|                                      AbnormalImpulseRelayEA.mq4  |
//|  异常 Tick 动量 + 回撤确认 + 单仓串行接力 EA                     |
//|                                                                  |
//|  核心原则：                                                      |
//|  1. 逐 Tick 监测，不等待 M1 K线收盘。                            |
//|  2. 使用历史分位数定义异常，不使用固定“100点”。                 |
//|  3. 异常出现后不追第一跳，等待 20%~45% 回撤及恢复确认。          |
//|  4. 固定小手数；同 Symbol + Magic 最多一张市场单。               |
//|  5. 同一异常事件最多串行交易三段。                               |
//|  6. 无固定止盈；使用结构SL、强反转、盈利动量衰减和盈利时间退出。 |
//|  7. 时间退出只对净盈利订单生效。                                 |
//|  8. 连续三笔净亏损后永久锁定，必须人工复位。                     |
//|                                                                  |
//|  重要说明：                                                      |
//|  - 第一版用于策略测试、前向验证和日志采集，不保证盈利。          |
//|  - 首次运行没有历史 Tick 样本时，只采集数据，不会立即交易。      |
//|  - 历史样本会保存到 MQL4/Files，重启后继续使用。                 |
//|  - 建议先在模拟账户和真实 Tick 数据环境中验证。                  |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Abnormal tick impulse, pullback entry and serial relay EA"

//====================================================================
// 一、输入参数：所有策略数值均由参数控制
//====================================================================

//--------------------------- 基本交易参数 ---------------------------
input int      InpMagicNumber                 = 26092701; // EA唯一Magic Number
input double   InpFixedLots                   = 0.01;     // 每次固定开仓手数
input int      InpSlippagePoints              = 20;       // 下单/平仓允许滑点（MT4 points）
input int      InpMaxLegsPerEvent             = 3;        // 每个异常事件最多交易段数
input int      InpCooldownSeconds             = 300;      // 事件结束后的冷却秒数
input int      InpEventMaxSeconds             = 300;      // 单个异常事件最长有效秒数
input bool     InpAllowLong                    = true;     // 是否允许做多
input bool     InpAllowShort                   = true;     // 是否允许做空

//--------------------------- Tick缓冲参数 ---------------------------
input int      InpTickBufferMinutes           = 5;        // Tick环形缓冲覆盖分钟数
input int      InpMaxTickBufferSize            = 60000;    // 环形缓冲最多保存Tick数
input int      InpWindow1Seconds              = 1;        // 第一个净变化窗口
input int      InpWindow3Seconds              = 3;        // 异常主触发短窗口
input int      InpWindow5Seconds              = 5;        // 辅助净变化窗口
input int      InpWindow10Seconds             = 10;       // 异常确认长窗口
input int      InpEfficiencyWindowSeconds     = 10;       // 方向效率计算窗口
input double   InpMinDirectionEfficiency      = 0.65;     // 异常冲击最低方向效率

//--------------------------- 历史统计参数 ---------------------------
input int      InpHistoryMaxSamples           = 100000;   // 每类历史样本最大数量
input int      InpHistoryMinSamples           = 2000;     // 允许交易前所需最少样本
input int      InpHistorySampleIntervalSec    = 1;        // 历史样本采样间隔秒数
input int      InpQuantileRefreshSeconds      = 60;       // 分位数重新计算间隔
input double   InpQuantile95Percent           = 95.0;     // Q95百分位
input double   InpQuantile99Percent           = 99.0;     // Q99百分位
input int      InpHistorySaveIntervalSeconds  = 300;      // 历史样本落盘间隔
input double   InpMinimumImpulsePoints        = 0.0;      // 动态阈值之外的最小冲击点数；0=禁用

//--------------------------- 异常信号参数 ---------------------------
input double   InpShortWindowQMultiplier      = 1.0;      // 3秒Q99阈值乘数
input double   InpLongWindowQMultiplier       = 1.0;      // 10秒Q95阈值乘数
input double   InpSpreadQMultiplier           = 1.0;      // 当前点差相对历史Q95的乘数上限
input double   InpDirectionZeroTolerancePts   = 0.1;      // 判断方向时忽略的小变化点数

//--------------------------- 回撤入场参数 ---------------------------
input double   InpPullbackMinRatio            = 0.20;     // 最小回撤比例
input double   InpPullbackMaxRatio            = 0.45;     // 最大回撤比例
input double   InpResumeConfirmPoints         = 5.0;      // 从回撤极值恢复多少点后确认入场
input double   InpResumeMove1MinPoints        = 0.0;      // 恢复时1秒同向净变化最小点数；0=只要求同向
input double   InpEventInvalidBufferPoints    = 0.0;      // 穿越冲击起点多少点后判事件失效
input bool     InpCooldownAfterInvalidEvent   = true;     // 无效事件后是否进入冷却

//--------------------------- 初始结构止损 ---------------------------
input double   InpInitialSLBufferPoints       = 10.0;     // SL放在回撤结构之外的缓冲点数
input double   InpBrokerStopSafetyPoints      = 2.0;      // 经纪商最小止损距离之外的额外安全点
input bool     InpRequireServerStopLoss       = true;     // 无法设置有效服务器SL时是否放弃开仓

//--------------------------- 结构跟踪止损 ---------------------------
input bool     InpEnableStructuralTrailing    = true;     // 是否启用结构跟踪止损
input double   InpTrailStartProfitPoints      = 20.0;     // 浮盈达到多少点后才开始跟踪
input int      InpTrailLookbackSeconds        = 5;        // 用最近多少秒局部低/高点跟踪
input double   InpTrailSLBufferPoints         = 8.0;      // 跟踪结构之外缓冲点数
input double   InpMinSLImprovePoints          = 2.0;      // 每次修改SL至少改善多少点

//--------------------------- 强反转退出 -----------------------------
input bool     InpEnableStrongReversalExit    = true;     // 盈利和亏损都适用的强反转退出
input double   InpReverseQ95Multiplier        = 1.0;      // 反方向3秒变化相对Q95的阈值乘数
input double   InpReverseMinEfficiency        = 0.65;     // 反向运动最低方向效率
input double   InpReverseMinDrawdownPoints    = 10.0;     // 从持仓后最佳价回撤的最小点数
input bool     InpReverseRequireMove10SameDir = true;     // 是否要求10秒变化也指向反方向

//--------------------------- 盈利动量衰减退出 -----------------------
input bool     InpEnableProfitFadeExit        = true;     // 是否启用盈利动量衰减退出
input double   InpFadeRetraceImpulseRatio     = 0.25;     // 从最佳价回撤达到冲击幅度的比例
input double   InpFadeMinimumPoints           = 10.0;     // 动量衰减最小回撤点数
input int      InpFadeNoNewExtremeSeconds     = 3;        // 最佳价多久未更新才允许衰减退出
input bool     InpFadeRequireMove3Opposite    = false;    // 是否必须3秒变化也反向

//--------------------------- 盈利时间退出 ---------------------------
input bool     InpEnableProfitTimeExit        = true;     // 是否启用盈利时间退出
input int      InpProfitTimeExitSeconds       = 30;       // 最短持仓秒数
input int      InpProfitStagnationSeconds     = 10;       // 最佳有利价格停滞秒数
input double   InpMinimumNetProfitForExit     = 0.0;      // 时间/衰减退出所需最低净利润（账户币种）

//--------------------------- 连续亏损熔断 ---------------------------
input int      InpMaxConsecutiveLosses        = 3;        // 达到多少次连续亏损后永久锁定
input double   InpBreakEvenToleranceMoney     = 0.01;     // 绝对净收益不超过此值视为保本
input bool     InpManualResetPermanentLock    = false;    // 改为true并重新加载EA：人工解除锁定

//--------------------------- 文件、日志及显示 -----------------------
input bool     InpPersistHistoricalSamples    = true;     // 是否保存/加载历史统计样本
input bool     InpEnableCsvEventLog           = true;     // 是否输出事件CSV日志
input bool     InpShowChartStatus             = true;     // 是否在图表显示EA状态
input int      InpFileFormatVersion           = 1;        // 历史样本文件格式版本

//====================================================================
// 二、数据类型与全局变量
//====================================================================

enum EA_STATE
{
   STATE_WARMUP = 0,          // 历史样本不足，只采集不交易
   STATE_NORMAL,              // 正常等待异常冲击
   STATE_WAIT_PULLBACK,       // 首段等待回撤和恢复
   STATE_POSITION_OPEN,       // 存在市场单
   STATE_WAIT_REENTRY,        // 前一段结束，等待下一段接力
   STATE_COOLDOWN,            // 事件结束后的冷却
   STATE_PERMANENT_LOCK       // 连续亏损永久锁定
};

// 单个Tick记录。localMs用于实盘亚秒计时；serverTime用于回测及跨会话判断。
struct TickRecord
{
   uint      localMs;
   datetime  serverTime;
   double    bid;
   double    ask;
   double    mid;
   double    spreadPoints;
};

TickRecord g_ticks[];
int        g_tickCapacity = 0;
int        g_tickCount    = 0;
int        g_tickHead     = 0;       // 下一条Tick写入位置

// 历史样本使用并行循环数组。每次采样同时写入五类值。
double g_histMove1[];
double g_histMove3[];
double g_histMove5[];
double g_histMove10[];
double g_histSpread[];
int    g_histCount = 0;
int    g_histHead  = 0;

// 当前动态分位数。
double g_q95Move1  = 0.0;
double g_q95Move3  = 0.0;
double g_q99Move3  = 0.0;
double g_q95Move5  = 0.0;
double g_q95Move10 = 0.0;
double g_q95Spread = 0.0;

// 当前短周期指标。
double g_move1  = 0.0;
double g_move3  = 0.0;
double g_move5  = 0.0;
double g_move10 = 0.0;
double g_efficiency = 0.0;
bool   g_metricsReady = false;

// EA运行状态。
EA_STATE g_state = STATE_WARMUP;
datetime g_lastHistorySampleTime = 0;
datetime g_lastQuantileTime      = 0;
datetime g_lastHistorySaveTime   = 0;
datetime g_cooldownEndTime       = 0;

// 当前异常事件。
bool     g_eventActive       = false;
int      g_eventDirection    = 0;    // +1上涨事件，-1下跌事件
datetime g_eventStartTime    = 0;
double   g_impulseStartPrice = 0.0;
double   g_impulseExtreme    = 0.0;
double   g_impulseRange      = 0.0;
int      g_legNumber         = 0;    // 已经成功开出的段数
bool     g_pullbackArmed     = false;
double   g_pullbackExtreme   = 0.0;

// 当前/最近订单跟踪。
int      g_trackedTicket     = -1;
double   g_bestPrice         = 0.0;
datetime g_bestPriceTime     = 0;
double   g_entryStructure    = 0.0;

// 连续亏损和永久锁定状态（同时写入终端全局变量）。
int      g_consecutiveLosses = 0;
bool     g_permanentLock     = false;
int      g_lastProcessedTicket = -1;

// 文件及全局变量名称。
string   g_historyFileName = "";
string   g_logFileName     = "";
string   g_gvLockName      = "";
string   g_gvLossName      = "";
string   g_gvLastTicketName= "";

//====================================================================
// 三、通用辅助函数
//====================================================================

string StateToString(EA_STATE state)
{
   switch(state)
   {
      case STATE_WARMUP:         return "WARMUP";
      case STATE_NORMAL:         return "NORMAL";
      case STATE_WAIT_PULLBACK:  return "WAIT_PULLBACK";
      case STATE_POSITION_OPEN:  return "POSITION_OPEN";
      case STATE_WAIT_REENTRY:   return "WAIT_REENTRY";
      case STATE_COOLDOWN:       return "COOLDOWN";
      case STATE_PERMANENT_LOCK: return "PERMANENT_LOCK";
   }
   return "UNKNOWN";
}

// 将文件名中可能有问题的字符替换掉。
string SafeName(string value)
{
   StringReplace(value, ".", "_");
   StringReplace(value, "#", "_");
   StringReplace(value, " ", "_");
   StringReplace(value, "/", "_");
   StringReplace(value, "\\", "_");
   return value;
}

// 构建区分账户、品种、Magic及测试环境的唯一名称。
void BuildNames()
{
   string mode = IsTesting() ? "TEST" : "LIVE";
   string key  = IntegerToString(AccountNumber()) + "_" + SafeName(Symbol()) + "_" +
                 IntegerToString(InpMagicNumber) + "_" + mode;

   g_historyFileName  = "AIREA_History_" + key + ".bin";
   g_logFileName      = "AIREA_Log_" + key + ".csv";
   g_gvLockName       = "AIREA_LOCK_" + key;
   g_gvLossName       = "AIREA_LOSS_" + key;
   g_gvLastTicketName = "AIREA_LAST_" + key;
}

// 统一写事件日志。只记录关键事件，不逐Tick写文件，避免拖慢OnTick。
void LogEvent(string eventName, string details)
{
   Print("[AIREA] ", eventName, " | ", details);

   if(!InpEnableCsvEventLog)
      return;

   int handle = FileOpen(g_logFileName,
                         FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,
                         ',');
   if(handle == INVALID_HANDLE)
   {
      Print("[AIREA] 无法打开日志文件，错误=", GetLastError());
      return;
   }

   // 空文件先写表头；否则定位到文件尾追加。
   if(FileSize(handle) == 0)
      FileWrite(handle, "ServerTime", "Event", "State", "Symbol", "Details");
   else
      FileSeek(handle, 0, SEEK_END);

   FileWrite(handle,
             TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
             eventName,
             StateToString(g_state),
             Symbol(),
             details);
   FileClose(handle);
}

// 返回Tick相对当前时刻的年龄（毫秒）。
// 实盘采用GetTickCount以获得亚秒分辨率；测试器采用服务器秒级时间。
uint TickAgeMs(const TickRecord &tick, uint nowLocalMs, datetime nowServerTime)
{
   if(IsTesting())
   {
      int seconds = (int)(nowServerTime - tick.serverTime);
      if(seconds < 0) seconds = 0;
      return (uint)seconds * 1000;
   }

   // uint无符号减法可自然处理GetTickCount约49.7天回绕。
   return (uint)(nowLocalMs - tick.localMs);
}

// 将价格标准化为当前品种的小数位。
double NormalizePrice(double price)
{
   return NormalizeDouble(price, Digits);
}

// 按经纪商最小手数、最大手数和步长规范化固定手数。
double NormalizeLots(double lots)
{
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double step   = MarketInfo(Symbol(), MODE_LOTSTEP);

   if(step <= 0.0) step = minLot;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / step + 0.0000001) * step;

   int lotDigits = 2;
   if(step >= 1.0) lotDigits = 0;
   else if(step >= 0.1) lotDigits = 1;
   else if(step >= 0.01) lotDigits = 2;
   else lotDigits = 3;

   return NormalizeDouble(lots, lotDigits);
}

//====================================================================
// 四、Tick环形缓冲与窗口指标
//====================================================================

void AddCurrentTick()
{
   RefreshRates();

   TickRecord item;
   item.localMs     = GetTickCount();
   item.serverTime  = TimeCurrent();
   item.bid         = Bid;
   item.ask         = Ask;
   item.mid         = (Bid + Ask) * 0.5;
   item.spreadPoints= (Ask - Bid) / Point;

   g_ticks[g_tickHead] = item;
   g_tickHead = (g_tickHead + 1) % g_tickCapacity;
   if(g_tickCount < g_tickCapacity)
      g_tickCount++;

   // 环形数组除了受最大容量限制，还按时间删除超过设定分钟数的旧Tick。
   // 因此在Tick频率不超过容量上限时，缓冲区严格代表“最近N分钟”。
   uint keepMs = (uint)InpTickBufferMinutes * 60 * 1000;
   while(g_tickCount > 1)
   {
      int oldestIndex = g_tickHead - g_tickCount;
      while(oldestIndex < 0) oldestIndex += g_tickCapacity;
      oldestIndex %= g_tickCapacity;

      if(TickAgeMs(g_ticks[oldestIndex], item.localMs, item.serverTime) <= keepMs)
         break;
      g_tickCount--;
   }
}

// offset=0返回最新Tick；offset=1返回倒数第二条，以此类推。
int TickIndexFromNewest(int offset)
{
   int index = g_tickHead - 1 - offset;
   while(index < 0) index += g_tickCapacity;
   return index % g_tickCapacity;
}

// 获取至少secondsAgo以前的最近一条Tick中间价。
bool GetMidPriceAgo(int secondsAgo, double &price)
{
   if(g_tickCount <= 0 || secondsAgo < 0)
      return false;

   uint nowMs = GetTickCount();
   datetime nowServer = TimeCurrent();
   uint targetMs = (uint)secondsAgo * 1000;

   for(int offset=0; offset<g_tickCount; offset++)
   {
      int idx = TickIndexFromNewest(offset);
      if(TickAgeMs(g_ticks[idx], nowMs, nowServer) >= targetMs)
      {
         price = g_ticks[idx].mid;
         return true;
      }
   }
   return false;
}

// 计算指定窗口内的方向效率。
// 净位移 / Tick路径总长度；快速单向行情趋近1，来回震荡趋近0。
bool CalculateEfficiency(int windowSeconds, double &efficiency)
{
   efficiency = 0.0;
   if(g_tickCount < 2)
      return false;

   uint nowMs = GetTickCount();
   datetime nowServer = TimeCurrent();
   uint targetMs = (uint)windowSeconds * 1000;

   int newestIdx = TickIndexFromNewest(0);
   double newest = g_ticks[newestIdx].mid;
   double previous = newest;
   double oldest = newest;
   double path = 0.0;
   bool enoughTime = false;

   for(int offset=1; offset<g_tickCount; offset++)
   {
      int idx = TickIndexFromNewest(offset);
      double value = g_ticks[idx].mid;
      path += MathAbs(previous - value);
      previous = value;
      oldest = value;

      if(TickAgeMs(g_ticks[idx], nowMs, nowServer) >= targetMs)
      {
         enoughTime = true;
         break;
      }
   }

   if(!enoughTime || path <= 0.0)
      return false;

   efficiency = MathAbs(newest - oldest) / path;
   return true;
}

// 获取最近lookbackSeconds内的Bid低点或Ask高点，用于结构跟踪止损。
bool GetRecentTradeExtreme(int lookbackSeconds, bool wantLow, double &extreme)
{
   if(g_tickCount <= 0)
      return false;

   uint nowMs = GetTickCount();
   datetime nowServer = TimeCurrent();
   uint targetMs = (uint)lookbackSeconds * 1000;
   bool initialized = false;

   for(int offset=0; offset<g_tickCount; offset++)
   {
      int idx = TickIndexFromNewest(offset);
      double value = wantLow ? g_ticks[idx].bid : g_ticks[idx].ask;

      if(!initialized)
      {
         extreme = value;
         initialized = true;
      }
      else if(wantLow)
         extreme = MathMin(extreme, value);
      else
         extreme = MathMax(extreme, value);

      if(TickAgeMs(g_ticks[idx], nowMs, nowServer) >= targetMs)
         return true;
   }
   return false;
}

void UpdateShortWindowMetrics()
{
   g_metricsReady = false;
   if(g_tickCount <= 0)
      return;

   double p1, p3, p5, p10;
   if(!GetMidPriceAgo(InpWindow1Seconds, p1))   return;
   if(!GetMidPriceAgo(InpWindow3Seconds, p3))   return;
   if(!GetMidPriceAgo(InpWindow5Seconds, p5))   return;
   if(!GetMidPriceAgo(InpWindow10Seconds, p10)) return;

   int newestIdx = TickIndexFromNewest(0);
   double nowMid = g_ticks[newestIdx].mid;

   g_move1  = nowMid - p1;
   g_move3  = nowMid - p3;
   g_move5  = nowMid - p5;
   g_move10 = nowMid - p10;

   if(!CalculateEfficiency(InpEfficiencyWindowSeconds, g_efficiency))
      return;

   g_metricsReady = true;
}

//====================================================================
// 五、历史样本、分位数与持久化
//====================================================================

void AddHistorySample()
{
   if(!g_metricsReady)
      return;

   int idx = g_histHead;
   g_histMove1[idx]  = MathAbs(g_move1);
   g_histMove3[idx]  = MathAbs(g_move3);
   g_histMove5[idx]  = MathAbs(g_move5);
   g_histMove10[idx] = MathAbs(g_move10);
   g_histSpread[idx] = (Ask - Bid) / Point;

   g_histHead = (g_histHead + 1) % InpHistoryMaxSamples;
   if(g_histCount < InpHistoryMaxSamples)
      g_histCount++;
}

// 对当前有效样本计算百分位。采用相邻排序值线性插值。
double CalculatePercentile(double &source[], int count, double percentile)
{
   if(count <= 0)
      return 0.0;

   double temp[];
   ArrayResize(temp, count);
   for(int i=0; i<count; i++)
      temp[i] = source[i];

   ArraySort(temp, WHOLE_ARRAY, 0, MODE_ASCEND);

   double p = MathMax(0.0, MathMin(100.0, percentile));
   double rank = (p / 100.0) * (count - 1);
   int lower = (int)MathFloor(rank);
   int upper = (int)MathCeil(rank);

   if(lower == upper)
      return temp[lower];

   double weight = rank - lower;
   return temp[lower] * (1.0 - weight) + temp[upper] * weight;
}

void RecalculateQuantiles()
{
   if(g_histCount <= 0)
      return;

   g_q95Move1  = CalculatePercentile(g_histMove1,  g_histCount, InpQuantile95Percent);
   g_q95Move3  = CalculatePercentile(g_histMove3,  g_histCount, InpQuantile95Percent);
   g_q99Move3  = CalculatePercentile(g_histMove3,  g_histCount, InpQuantile99Percent);
   g_q95Move5  = CalculatePercentile(g_histMove5,  g_histCount, InpQuantile95Percent);
   g_q95Move10 = CalculatePercentile(g_histMove10, g_histCount, InpQuantile95Percent);
   g_q95Spread = CalculatePercentile(g_histSpread, g_histCount, InpQuantile95Percent);

   g_lastQuantileTime = TimeCurrent();
}

bool HistoryReady()
{
   return (g_histCount >= InpHistoryMinSamples &&
           g_q99Move3 > 0.0 && g_q95Move10 > 0.0 && g_q95Spread > 0.0);
}

void SaveHistorySamples()
{
   if(!InpPersistHistoricalSamples || g_histCount <= 0)
      return;

   // 先删除旧文件，确保新文件不会残留旧尾部数据。
   FileDelete(g_historyFileName);
   int handle = FileOpen(g_historyFileName, FILE_WRITE|FILE_BIN);
   if(handle == INVALID_HANDLE)
   {
      Print("[AIREA] 保存历史样本失败，错误=", GetLastError());
      return;
   }

   FileWriteInteger(handle, InpFileFormatVersion, INT_VALUE);
   FileWriteInteger(handle, g_histCount, INT_VALUE);

   // 按当前数组物理顺序保存；分位数不依赖时间顺序。
   for(int i=0; i<g_histCount; i++)
   {
      FileWriteDouble(handle, g_histMove1[i]);
      FileWriteDouble(handle, g_histMove3[i]);
      FileWriteDouble(handle, g_histMove5[i]);
      FileWriteDouble(handle, g_histMove10[i]);
      FileWriteDouble(handle, g_histSpread[i]);
   }

   FileClose(handle);
   g_lastHistorySaveTime = TimeCurrent();
}

void LoadHistorySamples()
{
   if(!InpPersistHistoricalSamples)
      return;

   int handle = FileOpen(g_historyFileName, FILE_READ|FILE_BIN);
   if(handle == INVALID_HANDLE)
      return; // 首次运行没有文件属于正常情况。

   int version = FileReadInteger(handle, INT_VALUE);
   int savedCount = FileReadInteger(handle, INT_VALUE);

   if(version != InpFileFormatVersion || savedCount < 0)
   {
      FileClose(handle);
      Print("[AIREA] 历史样本文件版本不匹配，忽略旧文件。");
      return;
   }

   int countToRead = MathMin(savedCount, InpHistoryMaxSamples);
   for(int i=0; i<countToRead && !FileIsEnding(handle); i++)
   {
      g_histMove1[i]  = FileReadDouble(handle);
      g_histMove3[i]  = FileReadDouble(handle);
      g_histMove5[i]  = FileReadDouble(handle);
      g_histMove10[i] = FileReadDouble(handle);
      g_histSpread[i] = FileReadDouble(handle);
      g_histCount++;
   }

   FileClose(handle);
   g_histHead = g_histCount % InpHistoryMaxSamples;

   if(g_histCount > 0)
      RecalculateQuantiles();

   LogEvent("HISTORY_LOADED", "samples=" + IntegerToString(g_histCount));
}

void MaintainHistoricalStatistics()
{
   datetime now = TimeCurrent();

   if(g_metricsReady &&
      (g_lastHistorySampleTime == 0 || now - g_lastHistorySampleTime >= InpHistorySampleIntervalSec))
   {
      AddHistorySample();
      g_lastHistorySampleTime = now;
   }

   if(g_histCount > 0 &&
      (g_lastQuantileTime == 0 || now - g_lastQuantileTime >= InpQuantileRefreshSeconds))
      RecalculateQuantiles();

   if(InpPersistHistoricalSamples && g_histCount > 0 &&
      (g_lastHistorySaveTime == 0 || now - g_lastHistorySaveTime >= InpHistorySaveIntervalSeconds))
      SaveHistorySamples();
}

//====================================================================
// 六、订单查找与交易权限
//====================================================================

bool IsOurSelectedOrder()
{
   return (OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagicNumber);
}

// 查找本EA当前市场单。按设计最多只能找到一张。
bool FindOpenMarketOrder(int &ticket)
{
   ticket = -1;
   for(int pos=OrdersTotal()-1; pos>=0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(!IsOurSelectedOrder())
         continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL)
         continue;

      ticket = OrderTicket();
      return true;
   }
   return false;
}

// 开仓前检查同Symbol + Magic的任何市场单或挂单。
bool HasAnyEAOrder()
{
   for(int pos=OrdersTotal()-1; pos>=0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(IsOurSelectedOrder())
         return true;
   }
   return false;
}

bool CanSendTrade()
{
   if(g_permanentLock)
      return false;
   if(!IsConnected())
      return false;
   if(!IsTradeAllowed())
      return false;
   if(HasAnyEAOrder())
      return false;
   return true;
}

//====================================================================
// 七、异常事件识别与回撤入场
//====================================================================

int SignWithTolerance(double value, double tolerancePrice)
{
   if(value > tolerancePrice)  return 1;
   if(value < -tolerancePrice) return -1;
   return 0;
}

bool SpreadIsAcceptable()
{
   if(g_q95Spread <= 0.0)
      return false;
   double currentSpread = (Ask - Bid) / Point;
   return (currentSpread <= g_q95Spread * InpSpreadQMultiplier);
}

bool DetectAbnormalImpulse()
{
   if(!HistoryReady() || !g_metricsReady || !SpreadIsAcceptable())
      return false;

   double tolerance = InpDirectionZeroTolerancePts * Point;
   int dir3  = SignWithTolerance(g_move3, tolerance);
   int dir10 = SignWithTolerance(g_move10, tolerance);

   if(dir3 == 0 || dir10 == 0 || dir3 != dir10)
      return false;
   if(dir3 > 0 && !InpAllowLong)
      return false;
   if(dir3 < 0 && !InpAllowShort)
      return false;

   double shortThreshold = MathMax(g_q99Move3 * InpShortWindowQMultiplier,
                                   InpMinimumImpulsePoints * Point);
   double longThreshold  = MathMax(g_q95Move10 * InpLongWindowQMultiplier,
                                   InpMinimumImpulsePoints * Point);

   if(MathAbs(g_move3) < shortThreshold)
      return false;
   if(MathAbs(g_move10) < longThreshold)
      return false;
   if(g_efficiency < InpMinDirectionEfficiency)
      return false;

   g_eventActive       = true;
   g_eventDirection    = dir3;
   g_eventStartTime    = TimeCurrent();
   g_impulseStartPrice = ((Bid + Ask) * 0.5) - g_move10;
   g_impulseExtreme    = (Bid + Ask) * 0.5;
   g_impulseRange      = MathAbs(g_impulseExtreme - g_impulseStartPrice);
   g_legNumber         = 0;
   g_pullbackArmed     = false;
   g_pullbackExtreme   = g_impulseExtreme;
   g_state             = STATE_WAIT_PULLBACK;

   LogEvent("IMPULSE_DETECTED",
            "dir=" + IntegerToString(g_eventDirection) +
            ";move3_pts=" + DoubleToString(g_move3/Point, 1) +
            ";move10_pts=" + DoubleToString(g_move10/Point, 1) +
            ";eff=" + DoubleToString(g_efficiency, 3));
   return true;
}

void UpdateEventExtreme()
{
   if(!g_eventActive)
      return;

   double mid = (Bid + Ask) * 0.5;
   if(g_eventDirection > 0)
      g_impulseExtreme = MathMax(g_impulseExtreme, mid);
   else
      g_impulseExtreme = MathMin(g_impulseExtreme, mid);

   g_impulseRange = MathAbs(g_impulseExtreme - g_impulseStartPrice);
}

double CurrentPullbackRatio()
{
   if(!g_eventActive || g_impulseRange <= 0.0)
      return 0.0;

   double mid = (Bid + Ask) * 0.5;
   if(g_eventDirection > 0)
      return (g_impulseExtreme - mid) / g_impulseRange;
   return (mid - g_impulseExtreme) / g_impulseRange;
}

bool EventIsInvalid()
{
   if(!g_eventActive)
      return true;

   if(TimeCurrent() - g_eventStartTime > InpEventMaxSeconds)
      return true;

   double mid = (Bid + Ask) * 0.5;
   double buffer = InpEventInvalidBufferPoints * Point;

   if(g_eventDirection > 0 && mid < g_impulseStartPrice - buffer)
      return true;
   if(g_eventDirection < 0 && mid > g_impulseStartPrice + buffer)
      return true;

   // 尚未武装回撤时，超过最大回撤意味着当前事件失效。
   if(CurrentPullbackRatio() > InpPullbackMaxRatio)
      return true;

   return false;
}

void ResetPullbackTracking()
{
   g_pullbackArmed = false;
   g_pullbackExtreme = (Bid + Ask) * 0.5;
}

// 检查20%~45%回撤后，价格是否重新恢复原方向。
bool PullbackEntryConfirmed()
{
   if(!g_eventActive || !g_metricsReady)
      return false;

   UpdateEventExtreme();
   double ratio = CurrentPullbackRatio();
   double mid   = (Bid + Ask) * 0.5;

   if(!g_pullbackArmed)
   {
      if(ratio >= InpPullbackMinRatio && ratio <= InpPullbackMaxRatio)
      {
         g_pullbackArmed   = true;
         g_pullbackExtreme = mid;
         LogEvent("PULLBACK_ARMED", "ratio=" + DoubleToString(ratio, 3));
      }
      return false;
   }

   // 回撤武装后继续更新回撤极值。
   if(g_eventDirection > 0)
      g_pullbackExtreme = MathMin(g_pullbackExtreme, mid);
   else
      g_pullbackExtreme = MathMax(g_pullbackExtreme, mid);

   if(ratio > InpPullbackMaxRatio)
      return false;

   double resumeDistance = InpResumeConfirmPoints * Point;
   double minMove1 = InpResumeMove1MinPoints * Point;

   if(g_eventDirection > 0)
   {
      bool priceRecovered = (mid >= g_pullbackExtreme + resumeDistance);
      bool moveRecovered  = (g_move1 > minMove1);
      return priceRecovered && moveRecovered;
   }

   bool priceRecovered = (mid <= g_pullbackExtreme - resumeDistance);
   bool moveRecovered  = (g_move1 < -minMove1);
   return priceRecovered && moveRecovered;
}

// 按回撤结构计算初始服务器止损，并满足经纪商最小止损距离。
bool BuildInitialStopLoss(int orderType, double openPrice, double &stopLoss)
{
   double brokerStopPts = MarketInfo(Symbol(), MODE_STOPLEVEL);
   double minimumDistance = (brokerStopPts + InpBrokerStopSafetyPoints) * Point;
   double structureBuffer = InpInitialSLBufferPoints * Point;

   if(orderType == OP_BUY)
   {
      stopLoss = g_pullbackExtreme - structureBuffer;
      if(openPrice - stopLoss < minimumDistance)
         stopLoss = openPrice - minimumDistance;
      if(stopLoss <= 0.0 || stopLoss >= openPrice)
         return false;
   }
   else
   {
      stopLoss = g_pullbackExtreme + structureBuffer;
      if(stopLoss - openPrice < minimumDistance)
         stopLoss = openPrice + minimumDistance;
      if(stopLoss <= openPrice)
         return false;
   }

   stopLoss = NormalizePrice(stopLoss);
   return true;
}

bool OpenEventOrder()
{
   if(!CanSendTrade() || !SpreadIsAcceptable())
      return false;

   RefreshRates();
   int orderType = (g_eventDirection > 0) ? OP_BUY : OP_SELL;
   double openPrice = (orderType == OP_BUY) ? Ask : Bid;
   double stopLoss = 0.0;

   bool slValid = BuildInitialStopLoss(orderType, openPrice, stopLoss);
   if(!slValid && InpRequireServerStopLoss)
   {
      LogEvent("ENTRY_REJECTED", "reason=invalid_server_sl");
      return false;
   }
   if(!slValid)
      stopLoss = 0.0;

   double lots = NormalizeLots(InpFixedLots);
   int nextLeg = g_legNumber + 1;
   string comment = "AIREA-L" + IntegerToString(nextLeg);

   ResetLastError();
   int ticket = OrderSend(Symbol(), orderType, lots, NormalizePrice(openPrice),
                          InpSlippagePoints, stopLoss, 0.0, comment,
                          InpMagicNumber, 0,
                          orderType == OP_BUY ? clrBlue : clrRed);

   if(ticket < 0)
   {
      int errorCode = GetLastError();
      LogEvent("ORDER_SEND_FAILED", "error=" + IntegerToString(errorCode));
      return false;
   }

   g_legNumber++;
   g_trackedTicket  = ticket;
   g_bestPrice      = (orderType == OP_BUY) ? Bid : Ask;
   g_bestPriceTime  = TimeCurrent();
   g_entryStructure = g_pullbackExtreme;
   g_state          = STATE_POSITION_OPEN;

   LogEvent("ORDER_OPENED",
            "ticket=" + IntegerToString(ticket) +
            ";leg=" + IntegerToString(g_legNumber) +
            ";lots=" + DoubleToString(lots, 2) +
            ";sl=" + DoubleToString(stopLoss, Digits));
   return true;
}

//====================================================================
// 八、持仓管理：无固定TP
//====================================================================

// 更新持仓后的最佳有利价格和当前事件极值。
void UpdateBestFavourablePrice(int orderType)
{
   if(orderType == OP_BUY)
   {
      if(Bid > g_bestPrice || g_bestPrice <= 0.0)
      {
         g_bestPrice = Bid;
         g_bestPriceTime = TimeCurrent();
      }
   }
   else
   {
      if(Ask < g_bestPrice || g_bestPrice <= 0.0)
      {
         g_bestPrice = Ask;
         g_bestPriceTime = TimeCurrent();
      }
   }

   UpdateEventExtreme();
}

// 只允许向降低风险方向修改SL，绝不放宽。
void TightenStructuralStop(int ticket)
{
   if(!InpEnableStructuralTrailing)
      return;
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
      return;

   int type = OrderType();
   if(type != OP_BUY && type != OP_SELL)
      return;

   RefreshRates();
   double profitPoints = (type == OP_BUY) ?
                         (Bid - OrderOpenPrice()) / Point :
                         (OrderOpenPrice() - Ask) / Point;
   if(profitPoints < InpTrailStartProfitPoints)
      return;

   double recentExtreme = 0.0;
   if(!GetRecentTradeExtreme(InpTrailLookbackSeconds, type == OP_BUY, recentExtreme))
      return;

   double stopLevelDistance = (MarketInfo(Symbol(), MODE_STOPLEVEL) +
                               InpBrokerStopSafetyPoints) * Point;
   double candidate;

   if(type == OP_BUY)
   {
      candidate = recentExtreme - InpTrailSLBufferPoints * Point;
      candidate = MathMin(candidate, Bid - stopLevelDistance);
      candidate = NormalizePrice(candidate);

      if(candidate <= 0.0) return;
      if(OrderStopLoss() > 0.0 && candidate <= OrderStopLoss() + InpMinSLImprovePoints*Point)
         return;
   }
   else
   {
      candidate = recentExtreme + InpTrailSLBufferPoints * Point;
      candidate = MathMax(candidate, Ask + stopLevelDistance);
      candidate = NormalizePrice(candidate);

      if(OrderStopLoss() > 0.0 && candidate >= OrderStopLoss() - InpMinSLImprovePoints*Point)
         return;
   }

   ResetLastError();
   bool modified = OrderModify(ticket, OrderOpenPrice(), candidate, 0.0, 0, clrNONE);
   if(modified)
      LogEvent("SL_TIGHTENED", "ticket=" + IntegerToString(ticket) +
                               ";newSL=" + DoubleToString(candidate, Digits));
   else
      Print("[AIREA] OrderModify失败 ticket=", ticket, " error=", GetLastError());
}

bool IsStrongMomentumReversal(int orderType)
{
   if(!InpEnableStrongReversalExit || !g_metricsReady || g_q95Move3 <= 0.0)
      return false;

   double drawdownPoints = (orderType == OP_BUY) ?
                           (g_bestPrice - Bid) / Point :
                           (Ask - g_bestPrice) / Point;
   if(drawdownPoints < InpReverseMinDrawdownPoints)
      return false;
   if(g_efficiency < InpReverseMinEfficiency)
      return false;

   double threshold = g_q95Move3 * InpReverseQ95Multiplier;

   if(orderType == OP_BUY)
   {
      if(g_move3 > -threshold) return false;
      if(InpReverseRequireMove10SameDir && g_move10 >= 0.0) return false;
      return true;
   }

   if(g_move3 < threshold) return false;
   if(InpReverseRequireMove10SameDir && g_move10 <= 0.0) return false;
   return true;
}

// 动量衰减退出仅供净盈利订单使用。
bool IsProfitMomentumFading(int orderType)
{
   if(!InpEnableProfitFadeExit || !g_metricsReady)
      return false;

   double impulsePoints = g_impulseRange / Point;
   double requiredRetrace = MathMax(InpFadeMinimumPoints,
                                    impulsePoints * InpFadeRetraceImpulseRatio);
   double drawdownPoints = (orderType == OP_BUY) ?
                           (g_bestPrice - Bid) / Point :
                           (Ask - g_bestPrice) / Point;

   if(drawdownPoints < requiredRetrace)
      return false;
   if(TimeCurrent() - g_bestPriceTime < InpFadeNoNewExtremeSeconds)
      return false;

   if(orderType == OP_BUY)
   {
      if(g_move1 >= 0.0) return false;
      if(InpFadeRequireMove3Opposite && g_move3 >= 0.0) return false;
      return true;
   }

   if(g_move1 <= 0.0) return false;
   if(InpFadeRequireMove3Opposite && g_move3 <= 0.0) return false;
   return true;
}

// 时间退出只对净盈利且最佳价已停滞的订单生效。
bool IsProfitTimeExit(datetime openTime, double netProfit)
{
   if(!InpEnableProfitTimeExit)
      return false;
   if(netProfit <= InpMinimumNetProfitForExit)
      return false;
   if(TimeCurrent() - openTime < InpProfitTimeExitSeconds)
      return false;
   if(TimeCurrent() - g_bestPriceTime < InpProfitStagnationSeconds)
      return false;
   return true;
}

bool CloseSelectedMarketOrder(string reason)
{
   int ticket = OrderTicket();
   int type   = OrderType();
   double lots = OrderLots();

   RefreshRates();
   double closePrice = (type == OP_BUY) ? Bid : Ask;

   ResetLastError();
   bool closed = OrderClose(ticket, lots, NormalizePrice(closePrice),
                            InpSlippagePoints, clrViolet);
   if(!closed)
   {
      LogEvent("ORDER_CLOSE_FAILED",
               "ticket=" + IntegerToString(ticket) +
               ";reason=" + reason +
               ";error=" + IntegerToString(GetLastError()));
      return false;
   }

   g_trackedTicket = ticket; // 下一Tick从历史订单读取最终佣金和净收益。
   LogEvent("ORDER_CLOSE_REQUEST_OK",
            "ticket=" + IntegerToString(ticket) + ";reason=" + reason);
   return true;
}

void ManageOpenPosition(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
      return;

   int type = OrderType();
   if(type != OP_BUY && type != OP_SELL)
      return;

   g_state = STATE_POSITION_OPEN;
   UpdateBestFavourablePrice(type);

   // 先收紧服务器端结构SL；该SL对盈利和亏损持仓都有效。
   TightenStructuralStop(ticket);

   // OrderModify可能改变当前选中的订单上下文，因此重新选择。
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
      return;

   double netProfit = OrderProfit() + OrderSwap() + OrderCommission();
   datetime openTime = OrderOpenTime();

   // 强反转退出：盈利和亏损都可触发。
   if(IsStrongMomentumReversal(type))
   {
      CloseSelectedMarketOrder("STRONG_REVERSAL");
      return;
   }

   // 以下两类退出严格限制为净盈利订单。
   if(netProfit > InpMinimumNetProfitForExit)
   {
      if(IsProfitMomentumFading(type))
      {
         CloseSelectedMarketOrder("PROFIT_MOMENTUM_FADE");
         return;
      }

      if(IsProfitTimeExit(openTime, netProfit))
      {
         CloseSelectedMarketOrder("PROFIT_TIME_STAGNATION");
         return;
      }
   }

   // 亏损且未出现强反转：不执行时间止损，继续由结构SL保护。
}

//====================================================================
// 九、订单关闭结果、连续亏损与永久锁定
//====================================================================

void SaveRiskState()
{
   GlobalVariableSet(g_gvLockName, g_permanentLock ? 1.0 : 0.0);
   GlobalVariableSet(g_gvLossName, (double)g_consecutiveLosses);
   GlobalVariableSet(g_gvLastTicketName, (double)g_lastProcessedTicket);
}

void LoadRiskState()
{
   if(GlobalVariableCheck(g_gvLockName))
      g_permanentLock = (GlobalVariableGet(g_gvLockName) > 0.5);
   if(GlobalVariableCheck(g_gvLossName))
      g_consecutiveLosses = (int)GlobalVariableGet(g_gvLossName);
   if(GlobalVariableCheck(g_gvLastTicketName))
      g_lastProcessedTicket = (int)GlobalVariableGet(g_gvLastTicketName);

   if(InpManualResetPermanentLock)
   {
      g_permanentLock = false;
      g_consecutiveLosses = 0;
      SaveRiskState();
      LogEvent("MANUAL_RESET", "permanent lock and loss counter cleared");
   }
}

void EnterPermanentLock(string reason)
{
   g_permanentLock = true;
   g_state = STATE_PERMANENT_LOCK;
   SaveRiskState();
   LogEvent("PERMANENT_LOCK", reason);
   Alert("AIREA permanently locked: ", Symbol(), " Magic=", InpMagicNumber,
         " losses=", g_consecutiveLosses);
}

// 根据历史订单最终净收益更新连续亏损计数。
void ProcessClosedTicket(int ticket)
{
   if(ticket <= 0 || ticket == g_lastProcessedTicket)
      return;
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY))
      return;
   if(!IsOurSelectedOrder())
      return;
   if(OrderType() != OP_BUY && OrderType() != OP_SELL)
      return;

   double net = OrderProfit() + OrderSwap() + OrderCommission();

   if(net < -InpBreakEvenToleranceMoney)
      g_consecutiveLosses++;
   else if(net > InpBreakEvenToleranceMoney)
      g_consecutiveLosses = 0;
   // 保本单既不增加，也不清零。

   g_lastProcessedTicket = ticket;
   g_trackedTicket = -1;
   SaveRiskState();

   LogEvent("ORDER_CLOSED",
            "ticket=" + IntegerToString(ticket) +
            ";net=" + DoubleToString(net, 2) +
            ";consecutiveLosses=" + IntegerToString(g_consecutiveLosses));

   if(g_consecutiveLosses >= InpMaxConsecutiveLosses)
   {
      EnterPermanentLock("maximum consecutive losses reached");
      return;
   }

   // 未锁定时决定接力或结束事件。
   if(g_eventActive && g_legNumber < InpMaxLegsPerEvent &&
      TimeCurrent() - g_eventStartTime <= InpEventMaxSeconds)
   {
      ResetPullbackTracking();
      g_state = STATE_WAIT_REENTRY;
   }
   else
   {
      g_eventActive = false;
      g_cooldownEndTime = TimeCurrent() + InpCooldownSeconds;
      g_state = STATE_COOLDOWN;
   }
}

bool TicketStillOpen(int ticket)
{
   if(ticket <= 0)
      return false;
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
      return false;
   return (OrderCloseTime() == 0 && IsOurSelectedOrder());
}

// 处理服务器SL、人工平仓或EA平仓后的最终历史结果。
void DetectTrackedOrderClosure()
{
   if(g_trackedTicket <= 0)
      return;
   if(TicketStillOpen(g_trackedTicket))
      return;

   ProcessClosedTicket(g_trackedTicket);
}

// 初次安装且没有持久化last ticket时，将最近历史单设为基线，避免重复统计旧交易。
void InitializeHistoryBaseline()
{
   if(g_lastProcessedTicket > 0)
      return;

   datetime newestTime = 0;
   int newestTicket = -1;
   for(int pos=OrdersHistoryTotal()-1; pos>=0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(!IsOurSelectedOrder()) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(OrderCloseTime() > newestTime)
      {
         newestTime = OrderCloseTime();
         newestTicket = OrderTicket();
      }
   }

   if(newestTicket > 0)
   {
      g_lastProcessedTicket = newestTicket;
      SaveRiskState();
   }
}

// 扫描最近一张本EA历史订单，用于处理以下情况：
// EA/MT4离线期间，原有订单被服务器SL关闭；EA重新启动时内存中的
// g_trackedTicket已经丢失，但持久化的lastProcessedTicket仍能帮助识别新结果。
void ScanNewestUnprocessedClosedOrder()
{
   datetime newestCloseTime = 0;
   int newestTicket = -1;

   for(int pos=OrdersHistoryTotal()-1; pos>=0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(!IsOurSelectedOrder()) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(OrderCloseTime() <= 0) continue;

      if(OrderCloseTime() > newestCloseTime)
      {
         newestCloseTime = OrderCloseTime();
         newestTicket = OrderTicket();
      }
   }

   if(newestTicket > 0 && newestTicket != g_lastProcessedTicket)
      ProcessClosedTicket(newestTicket);
}

//====================================================================
// 十、状态转换和图表状态
//====================================================================

void CancelCurrentEvent(string reason)
{
   LogEvent("EVENT_CANCELLED", reason);
   g_eventActive = false;
   g_pullbackArmed = false;

   if(InpCooldownAfterInvalidEvent)
   {
      g_cooldownEndTime = TimeCurrent() + InpCooldownSeconds;
      g_state = STATE_COOLDOWN;
   }
   else
      g_state = STATE_NORMAL;
}

void StartCooldown(string reason)
{
   LogEvent("COOLDOWN_STARTED", reason);
   g_eventActive = false;
   g_pullbackArmed = false;
   g_cooldownEndTime = TimeCurrent() + InpCooldownSeconds;
   g_state = STATE_COOLDOWN;
}

void UpdateChartStatus()
{
   if(!InpShowChartStatus)
   {
      Comment("");
      return;
   }

   double spread = (Ask - Bid) / Point;
   double pullback = g_eventActive ? CurrentPullbackRatio() : 0.0;
   int cooldownLeft = (int)MathMax(0, g_cooldownEndTime - TimeCurrent());

   string text =
      "Abnormal Impulse Relay EA\n" +
      "State: " + StateToString(g_state) +
      " | Locked: " + (g_permanentLock ? "YES" : "NO") + "\n" +
      "History: " + IntegerToString(g_histCount) + "/" + IntegerToString(InpHistoryMinSamples) +
      " | Losses: " + IntegerToString(g_consecutiveLosses) + "/" + IntegerToString(InpMaxConsecutiveLosses) + "\n" +
      "Move1/3/5/10 pts: " + DoubleToString(g_move1/Point,1) + " / " +
      DoubleToString(g_move3/Point,1) + " / " + DoubleToString(g_move5/Point,1) + " / " +
      DoubleToString(g_move10/Point,1) + "\n" +
      "Q99(3s): " + DoubleToString(g_q99Move3/Point,1) +
      " | Q95(10s): " + DoubleToString(g_q95Move10/Point,1) +
      " | Eff: " + DoubleToString(g_efficiency,3) + "\n" +
      "Spread/Q95: " + DoubleToString(spread,1) + " / " + DoubleToString(g_q95Spread,1) +
      " | EventDir: " + IntegerToString(g_eventDirection) +
      " | Leg: " + IntegerToString(g_legNumber) + "\n" +
      "Pullback: " + DoubleToString(pullback*100.0,1) + "%" +
      " | Cooldown: " + IntegerToString(cooldownLeft) + "s";

   Comment(text);
}

//====================================================================
// 十一、参数校验、初始化、卸载与主循环
//====================================================================

bool ValidateInputs()
{
   if(InpFixedLots <= 0.0) return false;
   if(InpMaxLegsPerEvent <= 0) return false;
   if(InpTickBufferMinutes <= 0 || InpMaxTickBufferSize < 100) return false;
   if(InpHistoryMaxSamples <= 0 || InpHistoryMinSamples <= 0) return false;
   if(InpHistoryMinSamples > InpHistoryMaxSamples) return false;
   if(InpHistorySampleIntervalSec <= 0 || InpQuantileRefreshSeconds <= 0) return false;
   if(InpWindow1Seconds <= 0 || InpWindow3Seconds <= 0 ||
      InpWindow5Seconds <= 0 || InpWindow10Seconds <= 0) return false;
   if(InpPullbackMinRatio < 0.0 || InpPullbackMaxRatio <= InpPullbackMinRatio) return false;
   if(InpPullbackMaxRatio >= 1.0) return false;
   if(InpMinDirectionEfficiency < 0.0 || InpMinDirectionEfficiency > 1.0) return false;
   if(InpQuantile95Percent <= 0.0 || InpQuantile95Percent >= 100.0) return false;
   if(InpQuantile99Percent <= InpQuantile95Percent || InpQuantile99Percent >= 100.0) return false;
   if(InpMaxConsecutiveLosses <= 0) return false;
   return true;
}

int OnInit()
{
   if(!ValidateInputs())
   {
      Print("[AIREA] 输入参数无效，请检查参数设置。");
      return INIT_PARAMETERS_INCORRECT;
   }

   BuildNames();

   g_tickCapacity = InpMaxTickBufferSize;
   ArrayResize(g_ticks, g_tickCapacity);

   ArrayResize(g_histMove1,  InpHistoryMaxSamples);
   ArrayResize(g_histMove3,  InpHistoryMaxSamples);
   ArrayResize(g_histMove5,  InpHistoryMaxSamples);
   ArrayResize(g_histMove10, InpHistoryMaxSamples);
   ArrayResize(g_histSpread, InpHistoryMaxSamples);

   LoadRiskState();
   InitializeHistoryBaseline();
   LoadHistorySamples();

   // 若离线期间有订单关闭，在开始新交易前先恢复其最终盈亏结果。
   ScanNewestUnprocessedClosedOrder();

   // 如果EA重启时已有本EA订单，继续管理该单，但不盲目恢复旧事件接力。
   int existingTicket;
   if(FindOpenMarketOrder(existingTicket))
   {
      g_trackedTicket = existingTicket;
      if(OrderSelect(existingTicket, SELECT_BY_TICKET, MODE_TRADES))
      {
         g_bestPrice = (OrderType() == OP_BUY) ? Bid : Ask;
         g_bestPriceTime = TimeCurrent();
      }
      g_legNumber = InpMaxLegsPerEvent; // 重启后该单结束即冷却，不自动续开。
      g_state = STATE_POSITION_OPEN;
   }
   else if(g_permanentLock)
      g_state = STATE_PERMANENT_LOCK;
   else if(HistoryReady())
      g_state = STATE_NORMAL;
   else
      g_state = STATE_WARMUP;

   LogEvent("EA_INITIALIZED",
            "state=" + StateToString(g_state) +
            ";history=" + IntegerToString(g_histCount));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   SaveRiskState();
   SaveHistorySamples();
   Comment("");
   Print("[AIREA] EA removed/deinitialized, reason=", reason);
}

void OnTick()
{
   // 1. 最先更新实时数据；所有后续逻辑使用当前Tick。
   AddCurrentTick();
   UpdateShortWindowMetrics();
   MaintainHistoricalStatistics();

   // 2. 无论是否锁定，只要已有订单就继续执行风险管理。
   int openTicket;
   if(FindOpenMarketOrder(openTicket))
   {
      g_trackedTicket = openTicket;
      ManageOpenPosition(openTicket);
      UpdateChartStatus();
      return;
   }

   // 3. 处理刚刚由SL、人工或EA关闭的订单及连续亏损计数。
   DetectTrackedOrderClosure();

   // 4. 永久锁定状态禁止任何新事件和新开仓，只继续采集数据。
   if(g_permanentLock)
   {
      g_state = STATE_PERMANENT_LOCK;
      UpdateChartStatus();
      return;
   }

   // 5. 历史样本不足时只学习，不交易。
   if(!HistoryReady())
   {
      g_state = STATE_WARMUP;
      UpdateChartStatus();
      return;
   }
   if(g_state == STATE_WARMUP)
      g_state = STATE_NORMAL;

   // 6. 状态机。
   switch(g_state)
   {
      case STATE_NORMAL:
         DetectAbnormalImpulse();
         break;

      case STATE_WAIT_PULLBACK:
      case STATE_WAIT_REENTRY:
         UpdateEventExtreme();

         if(EventIsInvalid())
         {
            CancelCurrentEvent("timeout, deep pullback or structure invalidation");
            break;
         }

         if(g_legNumber >= InpMaxLegsPerEvent)
         {
            StartCooldown("maximum legs reached");
            break;
         }

         if(PullbackEntryConfirmed())
            OpenEventOrder();
         break;

      case STATE_COOLDOWN:
         if(TimeCurrent() >= g_cooldownEndTime)
         {
            g_state = STATE_NORMAL;
            g_eventActive = false;
            g_eventDirection = 0;
            g_legNumber = 0;
            LogEvent("COOLDOWN_FINISHED", "ready for next event");
         }
         break;

      case STATE_POSITION_OPEN:
         // 正常情况下前面已经找到订单；到这里通常表示订单刚消失，
         // 下一Tick会由DetectTrackedOrderClosure完成处理。
         break;

      case STATE_PERMANENT_LOCK:
      case STATE_WARMUP:
         break;
   }

   UpdateChartStatus();
}
//+------------------------------------------------------------------+
