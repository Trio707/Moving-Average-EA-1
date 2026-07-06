//+------------------------------------------------------------------+
//|                                              Moving Averages.mq5 |
//|                             Copyright 2000-2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2000-2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.01"

#include <Trade\Trade.mqh>

input double MaximumRisk        = 0.02;    // Maximum Risk in percentage
input double DecreaseFactor     = 3;       // Descrease factor
input int    MovingPeriod       = 12;      // Moving Average period
input int    MovingShift        = 6;       // Moving Average shift
      int PartialCloseState = 0;


//--- NEW INPUTS (ADDED ONLY)
input int    StopLossPoints     = 200;     // Stop Loss in points
input int    TakeProfitPoints   = 400;     // Take Profit in points
//---

//--- Trading Time Window (Broker Time)
input int TradeStartHour   = 8;    // Trading start hour
input int TradeStartMinute = 0;    // Trading start minute
input int TradeEndHour     = 17;   // Trading end hour
input int TradeEndMinute   = 0;    // Trading end minute

//--- Break-even settings
input int BreakEvenTriggerPoints = 200;   // Profit in points to trigger BE
input int BreakEvenOffsetPoints  = 20;    // Offset in points from entry

//--- Partial Close settings
input bool EnablePartialClose = true;   // Enable partial close
input double AdverseClosePercent = 50.0; // % of position to close when SL is 50% reached

//--- Trading Days Filter
input bool TradeMonday    = true;
input bool TradeTuesday   = true;
input bool TradeWednesday = true;
input bool TradeThursday  = true;
input bool TradeFriday    = true;
input bool TradeSaturday  = false;
input bool TradeSunday    = false;


int    ExtHandle=0;
bool   ExtHedging=false;
CTrade ExtTrade;

#define MA_MAGIC 1234501

//Calculate optimal lot size                                    

double TradeSizeOptimized(void)
  {
   double price=0.0;
   double margin=0.0;

   if(!SymbolInfoDouble(_Symbol,SYMBOL_ASK,price))
      return(0.0);
   if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,1.0,price,margin))
      return(0.0);
   if(margin<=0.0)
      return(0.0);

   double lot=NormalizeDouble(AccountInfoDouble(ACCOUNT_MARGIN_FREE)*MaximumRisk/margin,2);

   if(DecreaseFactor>0)
     {
      HistorySelect(0,TimeCurrent());
      int orders=HistoryDealsTotal();
      int losses=0;

      for(int i=orders-1;i>=0;i--)
        {
         ulong ticket=HistoryDealGetTicket(i);
         if(ticket==0) break;

         if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol)
            continue;
         if(HistoryDealGetInteger(ticket,DEAL_MAGIC)!=MA_MAGIC)
            continue;

         double profit=HistoryDealGetDouble(ticket,DEAL_PROFIT);
         if(profit>0.0)
            break;
         if(profit<0.0)
            losses++;
        }

      if(losses>1)
         lot=NormalizeDouble(lot-lot*losses/DecreaseFactor,1);
     }

   double stepvol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   lot=stepvol*NormalizeDouble(lot/stepvol,0);

   double minvol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   if(lot<minvol)
      lot=minvol;

   double maxvol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(lot>maxvol)
      lot=maxvol;

   return(lot);
  }
  
  bool IsTradingTime()
  {
   datetime now = TimeCurrent();
   MqlDateTime t;
   TimeToStruct(now, t);

   int currentMinutes = t.hour * 60 + t.min;
   int startMinutes   = TradeStartHour * 60 + TradeStartMinute;
   int endMinutes     = TradeEndHour * 60 + TradeEndMinute;

   // Normal session (e.g. 08:00–17:00)
   if(startMinutes < endMinutes)
      return (currentMinutes >= startMinutes && currentMinutes <= endMinutes);

   // Overnight session (e.g. 22:00–02:00)
   return (currentMinutes >= startMinutes || currentMinutes <= endMinutes);
  }
  
  bool IsTradingDay()
{
   datetime now = TimeCurrent();
   MqlDateTime t;
   TimeToStruct(now, t);

   switch(t.day_of_week)
   {
      case 1: return TradeMonday;    // Monday
      case 2: return TradeTuesday;   // Tuesday
      case 3: return TradeWednesday; // Wednesday
      case 4: return TradeThursday;  // Thursday
      case 5: return TradeFriday;    // Friday
      case 6: return TradeSaturday;  // Saturday
      case 0: return TradeSunday;    // Sunday
   }
   return false;
}


  
//Check for open position conditions                               

void CheckForOpen(void)
  {
   MqlRates rt[2];

   if(CopyRates(_Symbol,_Period,0,2,rt)!=2)
      return;

   if(rt[1].tick_volume>1)
      return;
      
     if(!IsTradingTime())
   return;
   
     if(!IsTradingDay())
   return;
 

   double ma[1];
   if(CopyBuffer(ExtHandle,0,0,1,ma)!=1)
      return;

   ENUM_ORDER_TYPE signal=WRONG_VALUE;

   if(rt[0].open>ma[0] && rt[0].close<ma[0])
      signal=ORDER_TYPE_SELL;
   else
     {
      if(rt[0].open<ma[0] && rt[0].close>ma[0])
         signal=ORDER_TYPE_BUY;
     }

   if(signal!=WRONG_VALUE)
     {
      if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && Bars(_Symbol,_Period)>100)
        {
        
        // ✅ STEP 3 — RESET PARTIAL CLOSE STATE
        PartialCloseState = 0;
        
         double price = (signal==ORDER_TYPE_BUY) ? 
                        SymbolInfoDouble(_Symbol,SYMBOL_ASK) :
                        SymbolInfoDouble(_Symbol,SYMBOL_BID);

         double sl=0.0,tp=0.0;

         if(signal==ORDER_TYPE_BUY)
           {
            sl = price - StopLossPoints * _Point;
            tp = price + TakeProfitPoints * _Point;
           }
         else
           {
            sl = price + StopLossPoints * _Point;
            tp = price - TakeProfitPoints * _Point;
           }

         ExtTrade.PositionOpen(_Symbol,signal,TradeSizeOptimized(),price,sl,tp);
        }
     }
  }

//Check for close position conditions                           

void CheckForClose(void)
  {
 //  MqlRates rt[2];

//   if(CopyRates(_Symbol,_Period,0,2,rt)!=2)
  //    return;

//   if(rt[1].tick_volume>1)
  //    return;

   //double ma[1];
   //if(CopyBuffer(ExtHandle,0,0,1,ma)!=1)
     // return;

   //bool signal=false;
   //long type=PositionGetInteger(POSITION_TYPE);

   //if(type==POSITION_TYPE_BUY && rt[0].open>ma[0] && rt[0].close<ma[0])
    //  signal=true;

   //if(type==POSITION_TYPE_SELL && rt[0].open<ma[0] && rt[0].close>ma[0])
    //  signal=true;

  // if(signal)
    // {
      //if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && Bars(_Symbol,_Period)>100)
     //    ExtTrade.PositionClose(_Symbol,3);
     }
  //}

//Position select depending on netting or hedging                  

bool SelectPosition()
  {
   bool res=false;

   if(ExtHedging)
     {
      uint total=PositionsTotal();
      for(uint i=0;i<total;i++)
        {
         if(PositionGetSymbol(i)==_Symbol &&
            PositionGetInteger(POSITION_MAGIC)==MA_MAGIC)
           {
            res=true;
            break;
           }
        }
     }
   else
     {
      if(!PositionSelect(_Symbol))
         return(false);
      else
         return(PositionGetInteger(POSITION_MAGIC)==MA_MAGIC);
     }

   return(res);
  }

//Expert initialization function                                   
int OnInit(void)
  {
   ExtHedging=((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
               ==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

   ExtTrade.SetExpertMagicNumber(MA_MAGIC);
   ExtTrade.SetMarginMode();
   ExtTrade.SetTypeFillingBySymbol(Symbol());

   ExtHandle=iMA(_Symbol,_Period,MovingPeriod,MovingShift,MODE_SMA,PRICE_CLOSE);
   if(ExtHandle==INVALID_HANDLE)
      return(INIT_FAILED);

   return(INIT_SUCCEEDED);
  }
  
  void ManageBreakEven()
  {
   if(!PositionSelect(_Symbol))
      return;

   if(PositionGetInteger(POSITION_MAGIC) != MA_MAGIC)
      return;

   long   type       = PositionGetInteger(POSITION_TYPE);
   double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl         = PositionGetDouble(POSITION_SL);
   double tp         = PositionGetDouble(POSITION_TP);

   double price = (type == POSITION_TYPE_BUY) ?
                  SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double profitPoints;

   if(type == POSITION_TYPE_BUY)
      profitPoints = (price - openPrice) / _Point;
   else
      profitPoints = (openPrice - price) / _Point;

   if(profitPoints < BreakEvenTriggerPoints)
      return;

   double newSL;

   if(type == POSITION_TYPE_BUY)
      newSL = openPrice + BreakEvenOffsetPoints * _Point;
   else
      newSL = openPrice - BreakEvenOffsetPoints * _Point;

   // Do not move SL backwards
   if(type == POSITION_TYPE_BUY && (sl >= newSL && sl != 0.0))
      return;

   if(type == POSITION_TYPE_SELL && (sl <= newSL && sl != 0.0))
      return;

   ExtTrade.PositionModify(_Symbol, newSL, tp);
  }
  
  void ManagePartialClose()
  {
   if(!EnablePartialClose)
      return;

   if(!PositionSelect(_Symbol))
      return;

   if(PositionGetInteger(POSITION_MAGIC) != MA_MAGIC)
      return;

   long   type      = PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume    = PositionGetDouble(POSITION_VOLUME);
   double tp        = PositionGetDouble(POSITION_TP);

   if(tp == 0.0 || volume <= 0.0)
      return;

   double price = (type == POSITION_TYPE_BUY) ?
                  SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double tpDistancePoints;

   if(type == POSITION_TYPE_BUY)
      tpDistancePoints = (tp - openPrice) / _Point;
   else
      tpDistancePoints = (openPrice - tp) / _Point;

   if(tpDistancePoints <= 0)
      return;

   double progressPoints;

   if(type == POSITION_TYPE_BUY)
      progressPoints = (price - openPrice) / _Point;
   else
      progressPoints = (openPrice - price) / _Point;

   double step = tpDistancePoints * 0.25;

   double closeVolume = NormalizeDouble(volume * 0.25, 2);
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   if(closeVolume < minVol)
      return;

   if(progressPoints >= step && !(PartialCloseState & 1))
     {
      ExtTrade.PositionClosePartial(_Symbol, closeVolume);
      PartialCloseState |= 1;
     }

   if(progressPoints >= step * 2 && !(PartialCloseState & 2))
     {
      ExtTrade.PositionClosePartial(_Symbol, closeVolume);
      PartialCloseState |= 2;
     }

   if(progressPoints >= step * 3 && !(PartialCloseState & 4))
     {
      ExtTrade.PositionClosePartial(_Symbol, closeVolume);
      PartialCloseState |= 4;
     }
  }



//Expert tick function                                             
void OnTick(void)
  {
  
  ManageBreakEven();
  ManagePartialClose();
  ManageAdversePartialClose();
  
   if(!SelectPosition())
      CheckForOpen();
  }
//+------------------------------------------------------------------+
void ManageAdversePartialClose()
{
   if(!PositionSelect(_Symbol))
      return;

   if(PositionGetInteger(POSITION_MAGIC) != MA_MAGIC)
      return;

   // Bit 8 = adverse 50% SL partial already done
   if((PartialCloseState & 8)!=0)
      return;

   long   type      = PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl        = PositionGetDouble(POSITION_SL);
   double volume    = PositionGetDouble(POSITION_VOLUME);

   if(sl == 0.0 || volume <= 0.0)
      return;

   double price = (type == POSITION_TYPE_BUY) ?
                  SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double slDistancePoints;
   double adversePoints;

   if(type == POSITION_TYPE_BUY)
   {
      slDistancePoints = (openPrice - sl) / _Point;
      adversePoints   = (openPrice - price) / _Point;
   }
   else
   {
      slDistancePoints = (sl - openPrice) / _Point;
      adversePoints   = (price - openPrice) / _Point;
   }

   if(slDistancePoints <= 0)
      return;

  // 50% of SL distance
if(adversePoints >= slDistancePoints * 0.5)
{
   double percent = AdverseClosePercent;
   if(percent <= 0.0 || percent >= 100.0)
      return;

   double closeVolume = NormalizeDouble(volume * (percent / 100.0), 2);
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   if(closeVolume < minVol)
      return;

   ExtTrade.PositionClosePartial(_Symbol, closeVolume);
   PartialCloseState |= 8;
}

}
