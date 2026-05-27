//+------------------------------------------------------------------+
//|                                         MA_Bollinger_Trend.mq4 |
//|                       外汇专家趋势策略 - 移动平均线+布林通道组合 |
//|                                             基于Logic.txt需求实现 |
//| 🎯 入场条件（需同时满足）
//| 1. 长周期趋势确认（如H4周期）：快MA在慢MA之上为上升趋势，之下为下降趋势
//| 2. 短周期趋势一致（如H1周期）：短周期趋势方向与长周期一致  
//| 3. 布林通道信号：价格触及或突破布林通道边界
//|    - 买入信号：价格触及/突破下轨 + 趋势向上
//|    - 卖出信号：价格触及/突破上轨 + 趋势向下
//| 🚪 出场条件
//| - 止盈：固定点数止盈（TakeProfitPips参数）
//| - 止损：固定止损点数（StopLossPips）作为硬保护，同时可选趋势反转提前离场：
//|   - UseTrendReversalStop=true：固定止损 + 趋势反转双重保护
//|     买入持仓 → 趋势转为下降 → 立即平仓（不等打到固定止损）
//|     卖出持仓 → 趋势转为上升 → 立即平仓
//|   - UseTrendReversalStop=false：仅使用固定止损
//| ⚙️ 风险管理
//| - 交易频率：默认每周一次（可配置）
//| - 资金管理：可选基于账户余额的百分比风险计算
//| - 单一持仓：同时只持有一个仓位
//| 🔄 策略特点
//| - 趋势跟踪：只顺着长周期趋势方向交易
//| - 多时间框架确认：长周期定方向，短周期找入场
//| - 双重止损保护：固定止损（硬保护）+ 趋势反转提前离场（软保护）
//| - 低频交易：减少过度交易，等待高概率机会
//| 本质：等待趋势明确时，在回调到布林通道边界处顺势入场，
//|       固定止损控制风险，趋势反转或达到固定盈利目标时离场。
//| - NJin 2026 May 27
//+------------------------------------------------------------------+
#property copyright   "外汇专家趋势策略"
#property description "结合移动平均线、布林通道和多周期确认的趋势策略"
#property version     "2.00"
#property strict

//--- v2.00 更新说明
// 1. 止损机制重构：固定止损(StopLossPips)改为必设硬保护，不再允许订单SL=0
// 2. 趋势反转由"主止损"改为"提前离场"：趋势反转时不等打到固定SL即平仓
// 3. 每根新K线增加持仓状态(PrintPositionStatus)和行情走势(PrintMarketSnapshot)日志输出
// 4. 简化ExecuteTrade()：移除stopLossPips==0分支，统一设定硬止损
// 5. 默认参数调整：StopLossPips 50→100, TakeProfitPips 100→150

//--- 输入参数
// 移动平均线参数
input int    FastMAPeriod      = 50;      // 快速移动平均线周期
input int    SlowMAPeriod      = 200;     // 慢速移动平均线周期
input int    MAMethod          = MODE_SMA; // 移动平均线方法 (0=SMA,1=EMA,2=SMMA,3=LWMA)

// 布林通道参数
input int    BollingerPeriod   = 20;      // 布林通道周期
input double BollingerDeviation = 2.0;    // 布林通道标准差
input int    BollingerMethod   = MODE_SMA; // 布林通道MA方法 (0=SMA,1=EMA,2=SMMA,3=LWMA)
input int    BollingerShift    = 0;       // 布林通道偏移
input int    BollingerPrice    = PRICE_CLOSE; // 应用的价格

// 时间周期参数
input int    ShortTF           = PERIOD_H1;  // 短周期（入场信号）
input int    LongTF            = PERIOD_H4;  // 长周期（趋势确认）

// 交易管理参数
input double LotSize           = 0.1;     // 固定手数
input bool   UseMoneyManagement = false;   // 使用资金管理
input double RiskPercent       = 2.0;     // 风险百分比（如果使用资金管理）
input int    MagicNumber       = 202401;  // 魔术码
input string TradeComment      = "MA_Bollinger_Trend"; // 交易注释

// 止损止盈参数
input int    StopLossPips      = 100;     // 固定止损点数（硬止损保护，必设）
input int    TakeProfitPips    = 150;     // 固定止盈点数
input bool   UseTrendReversalStop = true; // 启用趋势反转提前离场（趋势反转时不等固定止损）

// 交易频率控制
input bool   LimitTradingFrequency = true; // 限制交易频率
input int    MinDaysBetweenTrades = 7;    // 最小交易间隔天数（每周一次）

//--- 全局变量
datetime lastTradeTime = 0;
double initialSLPoints[1000]; // 存储订单初始止损点数，索引为ticket % 1000

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // 初始化初始止损点数数组
   for(int i = 0; i < 1000; i++)
   {
      initialSLPoints[i] = 0;
   }
   
   Print("MA_Bollinger_Trend EA初始化成功");
   Print("参数：FastMA=", FastMAPeriod, ", SlowMA=", SlowMAPeriod);
   Print("Bollinger: Period=", BollingerPeriod, ", Deviation=", BollingerDeviation);
   Print("时间周期：Short=", TimeFrameToString(ShortTF), ", Long=", TimeFrameToString(LongTF));

   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 时间周期转字符串函数                                              |
//+------------------------------------------------------------------+
string TimeFrameToString(int tf)
{
   switch(tf)
   {
      case PERIOD_M1: return "M1";
      case PERIOD_M5: return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1: return "H1";
      case PERIOD_H4: return "H4";
      case PERIOD_D1: return "D1";
      case PERIOD_W1: return "W1";
      case PERIOD_MN1: return "MN1";
      default: return IntegerToString(tf);
   }
}

//+------------------------------------------------------------------+
//| 专家订单计数函数                                                 |
//+------------------------------------------------------------------+
int CountOrders()
{
   int count = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && 
         OrderSymbol() == Symbol() && 
         OrderMagicNumber() == MagicNumber)
      {
         count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| 检查是否可以交易（频率控制）                                      |
//+------------------------------------------------------------------+
bool CanTrade()
{
   if(!LimitTradingFrequency) return true;
   
   if(lastTradeTime == 0) return true;
   
   datetime currentTime = TimeCurrent();
   int daysSinceLastTrade = (int)((currentTime - lastTradeTime) / 86400);
   
   if(daysSinceLastTrade >= MinDaysBetweenTrades)
   {
      return true;
   }
   
   Print("交易频率限制：距离上次交易", daysSinceLastTrade, "天，需要等待", MinDaysBetweenTrades, "天");
   return false;
}

//+------------------------------------------------------------------+
//| 计算止损点数                                                    |
//+------------------------------------------------------------------+
int CalculateStopLossPips()
{
   Print("固定止损点数：", StopLossPips);
   if(UseTrendReversalStop)
      Print("  同时启用趋势反转提前离场");
   return StopLossPips;
}

//+------------------------------------------------------------------+
//| 计算手数                                                        |
//+------------------------------------------------------------------+
double CalculateLotSize(int stopLossPips)
{
   if(!UseMoneyManagement) return LotSize;
   
   double riskAmount = AccountBalance() * RiskPercent / 100.0;
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double stopLossValue = stopLossPips * Point * tickValue;
   
   if(stopLossValue > 0)
   {
      double lots = riskAmount / stopLossValue;
      lots = NormalizeDouble(lots, 2);
      
      // 检查最小最大手数限制
      double minLot = MarketInfo(Symbol(), MODE_MINLOT);
      double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
      lots = MathMax(lots, minLot);
      lots = MathMin(lots, maxLot);
      
      Print("资金管理计算：风险金额=", riskAmount, ", 止损价值=", stopLossValue, ", 手数=", lots);
      return lots;
   }
   
   return LotSize;
}

//+------------------------------------------------------------------+
//| 检查趋势方向（移动平均线）                                       |
//+------------------------------------------------------------------+
int CheckTrendDirection(int timeframe)
{
   // 获取快速和慢速移动平均线值
   double fastMA1 = iMA(Symbol(), timeframe, FastMAPeriod, 0, MAMethod, PRICE_CLOSE, 1);
   double fastMA2 = iMA(Symbol(), timeframe, FastMAPeriod, 0, MAMethod, PRICE_CLOSE, 2);
   double slowMA1 = iMA(Symbol(), timeframe, SlowMAPeriod, 0, MAMethod, PRICE_CLOSE, 1);
   double slowMA2 = iMA(Symbol(), timeframe, SlowMAPeriod, 0, MAMethod, PRICE_CLOSE, 2);
   
   // 检查数据有效性
   if(fastMA1 == 0 || fastMA2 == 0 || slowMA1 == 0 || slowMA2 == 0)
   {
      return 0;
   }
   
   // 快速MA在慢速MA之上为上升趋势，反之为下降趋势
   if(fastMA1 > slowMA1 && fastMA2 > slowMA2)
   {
      return 1; // 上升趋势
   }
   else if(fastMA1 < slowMA1 && fastMA2 < slowMA2)
   {
      return -1; // 下降趋势
   }
   
   return 0; // 无明确趋势
}

//+------------------------------------------------------------------+
//| 检查布林通道信号                                                |
//+------------------------------------------------------------------+
int CheckBollingerSignal(int timeframe, int trendDirection)
{
   // 获取布林通道上轨、中轨、下轨值
   double upperBand1 = iBands(Symbol(), timeframe, BollingerPeriod, BollingerDeviation, BollingerShift, BollingerPrice, MODE_UPPER, 1);
   double upperBand2 = iBands(Symbol(), timeframe, BollingerPeriod, BollingerDeviation, BollingerShift, BollingerPrice, MODE_UPPER, 2);
   double lowerBand1 = iBands(Symbol(), timeframe, BollingerPeriod, BollingerDeviation, BollingerShift, BollingerPrice, MODE_LOWER, 1);
   double lowerBand2 = iBands(Symbol(), timeframe, BollingerPeriod, BollingerDeviation, BollingerShift, BollingerPrice, MODE_LOWER, 2);
   
   // 获取收盘价
   double close1 = iClose(Symbol(), timeframe, 1);
   double close2 = iClose(Symbol(), timeframe, 2);
   
   // 检查数据有效性
   if(upperBand1 == 0 || upperBand2 == 0 || lowerBand1 == 0 || lowerBand2 == 0 || close1 == 0 || close2 == 0)
   {
      return 0;
   }
   
   // 检查买入信号：价格从下方触及或突破下轨，且趋势向上
   if(close1 <= lowerBand1 && close2 > lowerBand2 && trendDirection == 1)
   {
      return 1; // 买入信号
   }
   // 检查卖出信号：价格从上方触及或突破上轨，且趋势向下
   else if(close1 >= upperBand1 && close2 < upperBand2 && trendDirection == -1)
   {
      return -1; // 卖出信号
   }
   
   return 0; // 无信号
}

//+------------------------------------------------------------------+
//| 执行交易                                                        |
//+------------------------------------------------------------------+
void ExecuteTrade(int signal)
{
   if(!CanTrade()) return;
   
   if(CountOrders() > 0)
   {
      Print("已有持仓，不执行新交易");
      return;
   }
   
    int stopLossPips = CalculateStopLossPips();
    double lots = CalculateLotSize(stopLossPips);
    double stopLossPrice, takeProfitPrice;
    int orderType;
    double price;
    
    // 计算止盈点数（固定止盈）
    int takeProfitPips = TakeProfitPips;
    
    if(stopLossPips > 0)
       Print("止损点数=", stopLossPips, " 止盈点数=", takeProfitPips, " 风险回报比=", (takeProfitPips/(double)stopLossPips));
    
    if(signal == 1) // 买入
    {
       orderType = OP_BUY;
       price = Ask;
       stopLossPrice = price - stopLossPips * Point;
       takeProfitPrice = price + takeProfitPips * Point;
    }
    else if(signal == -1) // 卖出
    {
       orderType = OP_SELL;
       price = Bid;
       stopLossPrice = price + stopLossPips * Point;
       takeProfitPrice = price - takeProfitPips * Point;
    }
    else
    {
       return;
    }
    
    int ticket = OrderSend(Symbol(), orderType, lots, price, 3, 
                          stopLossPrice, takeProfitPrice, 
                          TradeComment, MagicNumber, 0, 
                          orderType == OP_BUY ? clrBlue : clrRed);
    
    if(ticket > 0)
    {
       int index = ticket % 1000;
       initialSLPoints[index] = stopLossPips;
       
       Print("交易执行成功：", (orderType == OP_BUY ? "买入" : "卖出"), 
             " 手数=", lots, " 价格=", price,
             " 止损=", stopLossPrice, "(", stopLossPips, "点)", " 止盈=", takeProfitPrice, "(", takeProfitPips, "点)");
       lastTradeTime = TimeCurrent();
    }
   else
   {
      Print("交易执行失败，错误代码：", GetLastError());
   }
}



//+------------------------------------------------------------------+
//| 专家主函数                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   // 每根新K线检查一次交易信号
   static datetime lastBarTime = 0;
   datetime currentBarTime = Time[0];
   
    if(lastBarTime != currentBarTime)
    {
       lastBarTime = currentBarTime;
       
       Print("");
       Print("████████ 新K线信号 ████████");
       
       // 显示持仓情况
       PrintPositionStatus();
       
       // 显示行情走势
       PrintMarketSnapshot();
       
       // 判断交易条件并执行
       int longTermTrend = CheckTrendDirection(LongTF);
       int shortTermTrend = CheckTrendDirection(ShortTF);
       int bollingerSignal = CheckBollingerSignal(ShortTF, longTermTrend);
       
       if(longTermTrend != 0 && shortTermTrend == longTermTrend && bollingerSignal != 0)
       {
          ExecuteTrade(bollingerSignal);
       }
    }
   
   // 检查趋势反转提前离场（配合固定止损双重保护）
   CheckTrendReversalStop();
}

//+------------------------------------------------------------------+
//| 打印持仓状态                                                      |
//+------------------------------------------------------------------+
void PrintPositionStatus()
{
   int posCount = CountOrders();
   
   Print("═══════════ [持仓状态] ═══════════");
   
   if(posCount == 0)
   {
      Print("  当前无持仓");
      Print("═══════════════════════════════════");
      return;
   }
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) &&
         OrderSymbol() == Symbol() &&
         OrderMagicNumber() == MagicNumber)
      {
         string posType = (OrderType() == OP_BUY ? "买入" : "卖出");
         double openPrice = OrderOpenPrice();
         double currentPrice = (OrderType() == OP_BUY ? Bid : Ask);
         double profitPips = (OrderType() == OP_BUY ? 
            (currentPrice - openPrice) / Point : 
            (openPrice - currentPrice) / Point);
         double sl = OrderStopLoss();
         double tp = OrderTakeProfit();
         
         Print("  订单#", OrderTicket(), " 类型:", posType,
               " 手数:", OrderLots(),
               " 开仓价:", openPrice,
               " 当前价:", currentPrice,
               " 浮动盈亏:", DoubleToString(profitPips, 1), "点");
         
         if(sl > 0 && tp > 0)
            Print("    止损:", sl, " (", DoubleToString(MathAbs(currentPrice - sl) / Point, 1), "点) 止盈:", tp);
         else if(sl > 0)
            Print("    止损:", sl, " (", DoubleToString(MathAbs(currentPrice - sl) / Point, 1), "点) 止盈=趋势反转");
         else if(tp > 0)
            Print("    止损=趋势反转 止盈:", tp, " (", DoubleToString(MathAbs(tp - currentPrice) / Point, 1), "点)");
         else
            Print("    止损=趋势反转 止盈=趋势反转");
      }
   }
   
   Print("═══════════════════════════════════");
}

//+------------------------------------------------------------------+
//| 打印行情走势                                                      |
//+------------------------------------------------------------------+
void PrintMarketSnapshot()
{
   int longTrend = CheckTrendDirection(LongTF);
   int shortTrend = CheckTrendDirection(ShortTF);
   int bbSignal = CheckBollingerSignal(ShortTF, longTrend);
   
   double fastMA_long = iMA(Symbol(), LongTF, FastMAPeriod, 0, MAMethod, PRICE_CLOSE, 1);
   double slowMA_long = iMA(Symbol(), LongTF, SlowMAPeriod, 0, MAMethod, PRICE_CLOSE, 1);
   double fastMA_short = iMA(Symbol(), ShortTF, FastMAPeriod, 0, MAMethod, PRICE_CLOSE, 1);
   double slowMA_short = iMA(Symbol(), ShortTF, SlowMAPeriod, 0, MAMethod, PRICE_CLOSE, 1);
   
   double bb_upper = iBands(Symbol(), ShortTF, BollingerPeriod, BollingerDeviation, BollingerShift, BollingerPrice, MODE_UPPER, 1);
   double bb_mid   = iBands(Symbol(), ShortTF, BollingerPeriod, BollingerDeviation, BollingerShift, BollingerPrice, MODE_MAIN, 1);
   double bb_lower = iBands(Symbol(), ShortTF, BollingerPeriod, BollingerDeviation, BollingerShift, BollingerPrice, MODE_LOWER, 1);
   double close_short = iClose(Symbol(), ShortTF, 1);
   
   string trendStr = (longTrend == 1 ? "↑ 上升" : (longTrend == -1 ? "↓ 下降" : "─ 震荡"));
   string shortStr = (shortTrend == 1 ? "↑ 上升" : (shortTrend == -1 ? "↓ 下降" : "─ 震荡"));
   
   Print("═══════════ [行情走势] ═══════════");
   Print("  时间:", TimeToString(Time[1], TIME_DATE|TIME_MINUTES));
   Print("  长周期(", TimeFrameToString(LongTF), "): ", trendStr,
         "  快MA=", DoubleToString(fastMA_long, Digits()),
         "  慢MA=", DoubleToString(slowMA_long, Digits()));
   Print("  短周期(", TimeFrameToString(ShortTF), "): ", shortStr,
         "  快MA=", DoubleToString(fastMA_short, Digits()),
         "  慢MA=", DoubleToString(slowMA_short, Digits()));
   Print("  布林通道(", TimeFrameToString(ShortTF), "): 上轨=", DoubleToString(bb_upper, Digits()),
         "  中轨=", DoubleToString(bb_mid, Digits()),
         "  下轨=", DoubleToString(bb_lower, Digits()));
   Print("  收盘价=", DoubleToString(close_short, Digits()),
         "  布林信号:", (bbSignal == 1 ? "买入(触及下轨)" : (bbSignal == -1 ? "卖出(触及上轨)" : "无信号")));
   
   if(longTrend != 0 && shortTrend == longTrend && bbSignal != 0)
      Print("  ★ 交易条件满足！方向:", (bbSignal == 1 ? "做多" : "做空"));
   else
      Print("  交易条件不满足");
   
   Print("═══════════════════════════════════");
}

//+------------------------------------------------------------------+
//| 检查趋势反转提前离场（固定止损之外的额外保护）                      |
//+------------------------------------------------------------------+
void CheckTrendReversalStop()
{
   if(!UseTrendReversalStop) return;
   
    // 获取长周期趋势方向（所有订单共享）
    int longTermTrend = CheckTrendDirection(LongTF);
    
    // 反向遍历订单，避免因平仓导致索引错位
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
       if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && 
          OrderSymbol() == Symbol() && 
          OrderMagicNumber() == MagicNumber)
       {
          int orderType = OrderType();
          int ticket = OrderTicket();
          
          // 检查趋势是否反转
          bool closePosition = false;
          if(orderType == OP_BUY && longTermTrend == -1) // 买入持仓但趋势转为下降
          {
             closePosition = true;
             Print("订单#", ticket, " 买入持仓，长周期趋势转为下降，触发趋势反转止损");
          }
          else if(orderType == OP_SELL && longTermTrend == 1) // 卖出持仓但趋势转为上升
          {
             closePosition = true;
             Print("订单#", ticket, " 卖出持仓，长周期趋势转为上升，触发趋势反转止损");
          }
          
          if(closePosition)
          {
             if(OrderClose(ticket, OrderLots(), 
                (orderType == OP_BUY ? Bid : Ask), 3, clrYellow))
             {
                Print("订单#", ticket, " 已平仓（趋势反转止损）");
             }
             else
             {
                Print("订单#", ticket, " 平仓失败，错误代码：", GetLastError());
             }
          }
       }
    }
}

//+------------------------------------------------------------------+