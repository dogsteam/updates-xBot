//+------------------------------------------------------------------+
//|                                                   xBotEAnew.mq5  |
//|        Bản mới: CLOSE_ALL chỉ đóng lệnh do bot tạo (comment)     |
//|        và ưu tiên đóng theo thứ tự "thông minh"                  |
//+------------------------------------------------------------------+
#property copyright "Copy Trade System"
#property link      ""
#property version   "3.20"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input string   SignalFile = "signal.txt";   // File name (must be in MQL5/Files/)
input double   LotPercentage = 100.0;       // Tỷ lệ khối lượng so với gốc (%)
input int      PollInterval = 10;           // Poll Interval (ms)
input bool     AutoDetectFillingMode = true; // Auto-detect Order Filling Mode

//--- Global variables
CTrade trade;
string g_lastSignal = "";  // Track last processed signal to avoid duplicates
ENUM_ORDER_TYPE_FILLING g_fillingMode = ORDER_FILLING_FOK;
long g_accountID = 0;      // Current MT5 Account ID
datetime g_lastOpenAt = 0; // Thời điểm mở lệnh gần nhất (anti-double entry)
long g_lastStatusMinuteBucket = -1; // Heartbeat status.txt: 1 lần/phút tại giây 17 (TimeLocal, không phụ thuộc tick)

// Struct for delayed reporting (comment = position comment for report filter bot/manual)
struct PendingReport {
   ulong masterTicket;
   ulong slaveTicket;
   datetime closeTime;
   string symbol;
   string comment;
};
PendingReport g_reports[];

bool IsBotComment(string comment)
{
   return (StringFind(comment, "xBot|") == 0) || (StringFind(comment, "bot-") == 0);
}

bool IsMatchMasterTicketComment(string comment, ulong masterTicket)
{
   string prefixXBot = "xBot|" + (string)masterTicket;
   return (StringFind(comment, prefixXBot) == 0) ||
          (StringFind(comment, "bot-") == 0 && StringFind(comment, "|" + (string)masterTicket) >= 0);
}

bool CanOpenNow(string &reason)
{
   datetime now = TimeCurrent();
   if (g_lastOpenAt > 0 && (now - g_lastOpenAt) < 30)
   {
      reason = "OPEN_BLOCKED_COOLDOWN_30S";
      return false;
   }
   return true;
}

void MarkOpenSuccess()
{
   g_lastOpenAt = TimeCurrent();
}

int CountBotPositions()
{
   int count = 0;
   for (int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if (!PositionSelectByTicket(ticket)) continue;
      if (IsBotComment(PositionGetString(POSITION_COMMENT))) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize trade object
   trade.SetExpertMagicNumber(123456);
   trade.SetDeviationInPoints(10);
   
   // Get and save Account ID and Balance for App authentication
   g_accountID = AccountInfoInteger(ACCOUNT_LOGIN);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   int h = FileOpen("auth.txt", FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h != INVALID_HANDLE) {
      FileWriteString(h, (string)g_accountID + "," + DoubleToString(balance, 2));
      FileClose(h);
      Print("Account info saved to auth.txt: ", g_accountID, " | Balance: ", balance);
   } else {
      Print("Failed to save auth.txt");
      ResetLastError();
   }
   
   // Set timer
   EventSetMillisecondTimer(PollInterval < 10 ? 10 : PollInterval);
   
   // Initial filling mode detection
   if (AutoDetectFillingMode) {
      DetectFillingMode(_Symbol);
   }
   
   // Diagnostic: Test file access
   ResetLastError();
   int testHandle = FileOpen(SignalFile, FILE_READ|FILE_WRITE|FILE_TXT|FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_ANSI);
   if (testHandle != INVALID_HANDLE) {
      FileClose(testHandle);
      Print("✓ Signal file access test: OK");
   } else {
      int testErr = GetLastError();
      if (testErr == 2) {
         Print("⚠ Signal file not found yet (will be created by xBotCoper.js): ", SignalFile);
      } else {
         Print("✗ Signal file access test FAILED. Error code: ", testErr);
         if (testErr == 5004) {
            Print("  → FILE_CANNOT_OPEN: Check file permissions in MQL5/Files/ directory");
            Print("  → Ensure xBotCoper.js has write access and file is not locked");
         }
      }
      ResetLastError();
   }
   
   Print("========================================");
   Print("xBotEAnew initialized");
   Print("Signal file: ", SignalFile);
   Print("Poll interval: ", PollInterval, "ms");
   Print("========================================");
   
   // Một lần khi khởi động — Client cần status.txt ngay (trước heartbeat phút:17)
   UpdateStatusFile();
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Timer function - Core logic                                      |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Đọc hết file một lần — client có thể gửi "một phát nhiều dòng", EA nhận hết và xử lý lần lượt
   string content = ReadAndClearSignalFile();
   
   if (content != "") {
      Print("Signal file content (", StringLen(content), " chars): ", content);
      string lines[];
      int count = StringSplit(content, '\n', lines);
      Print("Parsed ", count, " signal lines");
      for (int i = 0; i < count; i++) {
         string sig = StringTrim(lines[i]);
         if (sig != "") {
            ProcessSignal(sig);
         }
      }
   }
   
   // Heartbeat: ghi status.txt 1 lần/phút tại giây 17 (giờ máy). Dùng TimeLocal — TimeCurrent() bám tick, không tick thì không tới giây 17.
   datetime tLocal = TimeLocal();
   MqlDateTime dt;
   TimeToStruct(tLocal, dt);
   if (dt.sec == 17) {
      long minuteBucket = (long)(tLocal / 60);
      if (minuteBucket != g_lastStatusMinuteBucket) {
         g_lastStatusMinuteBucket = minuteBucket;
         UpdateStatusFile();
      }
   }
   
   // Process pending reports (10 seconds delay)
   ProcessPendingReports();
   
   // Append manual-closed deals (đóng tay) chưa gửi — dựa vào checkpoint (sent + appended)
   static datetime lastManualScan = 0;
   if (TimeCurrent() - lastManualScan >= 30) {
      lastManualScan = TimeCurrent();
      datetime sent = LoadReportSentCheckpoint();
      datetime appended = LoadReportAppendedCheckpoint();
      datetime since = (sent > appended) ? sent : appended;
      AppendManualDealsSince(since);
   }
}

//+------------------------------------------------------------------+
//| Read all signals and clear the file                              |
//+------------------------------------------------------------------+
string ReadAndClearSignalFile()
{
   string content = "";
   
   // Retry logic: Thử mở file tối đa 3 lần với delay nhỏ
   int maxRetries = 3;
   int retryDelay = 1; // 1ms delay giữa các lần retry
   int handle = INVALID_HANDLE;
   
   for (int attempt = 0; attempt < maxRetries; attempt++) {
      ResetLastError();
      
      // Chỉ đọc với FILE_READ và FILE_SHARE_READ|FILE_SHARE_WRITE
      // Không cần FILE_WRITE khi chỉ đọc
      handle = FileOpen(SignalFile, FILE_READ|FILE_TXT|FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_ANSI);
      
      if (handle != INVALID_HANDLE) {
         break; // Thành công, thoát khỏi retry loop
      }
      
      int openErr = GetLastError();
      
      // Nếu là FILE_NOT_FOUND (2), không cần retry
      if (openErr == 2) {
         ResetLastError();
         return ""; // File chưa tồn tại, trả về empty
      }
      
      // Nếu là lỗi khác và chưa hết retry, đợi một chút rồi thử lại
      if (attempt < maxRetries - 1) {
         Sleep(retryDelay);
         continue;
      }
      
      // Đã hết retry, log lỗi
      static datetime lastErrorLog = 0;
      if (TimeCurrent() - lastErrorLog > 60) { // Log mỗi 60 giây để tránh spam
         string errorMsg = "";
         if (openErr == 5004) {
            errorMsg = "FILE_CANNOT_OPEN (5004) - File locked or permission denied";
         } else if (openErr == 5002) {
            errorMsg = "FILE_WRONG_FILENAME (5002) - Invalid file path";
         } else {
            errorMsg = "Unknown error";
         }
         Print("ERROR: Cannot open signal file after ", maxRetries, " attempts: ", SignalFile);
         Print("  Error code: ", openErr, " (", errorMsg, ")");
         Print("  TIP: Check if xBotCoper.js is running and file permissions in MQL5/Files/");
         lastErrorLog = TimeCurrent();
      }
      ResetLastError();
      return ""; // Trả về empty nếu không mở được
   }
   
   // Đọc nội dung file
   if (handle != INVALID_HANDLE) {
      while (!FileIsEnding(handle)) {
         string line = FileReadString(handle);
         if (line != "") {
            content += line + "\n";
         }
      }
      FileClose(handle);
      
      int readErr = GetLastError();
      if (readErr != 0 && readErr != 1) {
         Print("WARNING: Error reading signal file: ", readErr);
      }
      ResetLastError();
      
      // Clear the file after reading — xóa nội dung bằng cách ghi đè
      if (content != "") {
         ResetLastError();
         // Thử xóa file bằng cách mở với FILE_WRITE và đóng ngay
         handle = FileOpen(SignalFile, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
         if (handle != INVALID_HANDLE) {
            FileClose(handle);
            Print("Signal file cleared after reading ", StringLen(content), " characters");
         } else {
            // Nếu không xóa được, không sao - lần sau sẽ đọc lại
            ResetLastError();
         }
      }
   }
   
   return content;
}

//+------------------------------------------------------------------+
//| Update status.txt with Balance and Equity                        |
//+------------------------------------------------------------------+
void UpdateStatusFile()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   int h = FileOpen("status.txt", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h != INVALID_HANDLE) {
      FileWriteString(h, (string)g_accountID + "," + DoubleToString(balance, 2) + "," + DoubleToString(equity, 2));
      FileClose(h);
   }
}

//+------------------------------------------------------------------+
//| Process Pending Reports (delayed by 20s — gom báo cáo, tránh 2 tin) |
//+------------------------------------------------------------------+
void ProcessPendingReports()
{
   int size = ArraySize(g_reports);
   if (size == 0) return;
   
   datetime now = TimeCurrent();
   for (int i = size - 1; i >= 0; i--) {
      if (now - g_reports[i].closeTime >= 20) {
         // This report is ready to be written
         WriteReportToFile(g_reports[i]);
         
         // Remove from array
         for (int j = i; j < size - 1; j++) g_reports[j] = g_reports[j+1];
         ArrayResize(g_reports, size - 1);
         size--;
      }
   }
}

//+------------------------------------------------------------------+
//| Write report to reports.txt                                      |
//+------------------------------------------------------------------+
void WriteReportToFile(PendingReport &rep)
{
   // Select history to find the closing deal details
   if (HistorySelect(rep.closeTime - 5, rep.closeTime + 5)) {
      int total = HistoryDealsTotal();
      for (int i = total - 1; i >= 0; i--) {
         ulong dealTicket = HistoryDealGetTicket(i);
         if (HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) == rep.slaveTicket &&
             HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            
            double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            double commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            double swap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            double netProfit = profit + commission + swap;
            
            double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
            long dealType = HistoryDealGetInteger(dealTicket, DEAL_TYPE); // 0=BUY, 1=SELL
            
            // Find the opening price for this position
            double openPrice = 0;
            for (int k = 0; k < total; k++) {
               ulong tOpen = HistoryDealGetTicket(k);
               if (HistoryDealGetInteger(tOpen, DEAL_POSITION_ID) == rep.slaveTicket &&
                   HistoryDealGetInteger(tOpen, DEAL_ENTRY) == DEAL_ENTRY_IN) {
                  openPrice = HistoryDealGetDouble(tOpen, DEAL_PRICE);
                  break;
               }
            }
            
            // Format: MASTER,SLAVE,SYMBOL,OPEN,CLOSE,PROFIT,TYPE,COMMENT,CLOSE_TIME (9 cột; cột 9 cho Client ghi checkpoint)
            string safeComment = rep.comment;
            StringReplace(safeComment, ",", ";"); // avoid breaking CSV
            long closeTimeUnix = (long)rep.closeTime;
            string reportLine = StringFormat("%I64u,%I64u,%s,%.5f,%.5f,%.2f,%d,%s,%d",
                               rep.masterTicket, rep.slaveTicket, rep.symbol, openPrice, closePrice, netProfit, (int)dealType, safeComment, closeTimeUnix);
            
            int h = FileOpen("reports.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
            if (h != INVALID_HANDLE) {
               FileSeek(h, 0, SEEK_END);
               FileWriteString(h, reportLine + "\r\n");
               FileClose(h);
               Print("Report written for Slave Ticket: ", rep.slaveTicket);
            }
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Đọc checkpoint "đã gửi đến thời điểm nào" (Client ghi sau khi POST /report thành công) |
//+------------------------------------------------------------------+
datetime LoadReportSentCheckpoint()
{
   string fname = "report_sent_" + (string)g_accountID + ".txt";
   int h = FileOpen(fname, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if (h == INVALID_HANDLE)
      return 0;
   string line = FileReadString(h);
   FileClose(h);
   if (line == "") return 0;
   long t = (long)StringToInteger(StringTrim(line));
   return (datetime)MathMax(0, t);
}

//+------------------------------------------------------------------+
//| Đọc checkpoint "đã append vào reports.txt đến thời điểm nào" (EA ghi để tránh trùng) |
//+------------------------------------------------------------------+
datetime LoadReportAppendedCheckpoint()
{
   string fname = "report_appended_" + (string)g_accountID + ".txt";
   int h = FileOpen(fname, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if (h == INVALID_HANDLE)
      return 0;
   string line = FileReadString(h);
   FileClose(h);
   if (line == "") return 0;
   long t = (long)StringToInteger(StringTrim(line));
   return (datetime)MathMax(0, t);
}

//+------------------------------------------------------------------+
//| Ghi checkpoint "đã append đến dealTime" (để lần sau không thêm lại) |
//+------------------------------------------------------------------+
void SaveReportAppendedCheckpoint(datetime dealTime)
{
   if (dealTime <= 0) return;
   string fname = "report_appended_" + (string)g_accountID + ".txt";
   int h = FileOpen(fname, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if (h != INVALID_HANDLE) {
      FileWriteString(h, IntegerToString((long)dealTime));
      FileClose(h);
   }
}

//+------------------------------------------------------------------+
//| Thêm vào reports.txt các lệnh đóng TAY (manual) chưa gửi — DEAL_TIME > lastSentTime, comment không phải bot |
//+------------------------------------------------------------------+
void AppendManualDealsSince(datetime lastSentTime)
{
   // Chỉ thêm lệnh tay khi đã có checkpoint (đã gửi turn trước) — tránh trùng / flood lần đầu
   if (lastSentTime <= 0) return;
   datetime fromT = lastSentTime;
   if (!HistorySelect(fromT, TimeCurrent() + 60))
      return;
   
   int total = HistoryDealsTotal();
   if (total == 0) return;
   
   string linesToAdd = "";
   int added = 0;
   datetime maxDealTime = 0;
   
   for (int i = total - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if (HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      
      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if (dealTime <= lastSentTime)
         continue;
      
      string comment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
      if (StringFind(comment, "xBot|") == 0 || StringFind(comment, "bot-") == 0)
         continue; // lệnh bot — đã ghi qua WriteReportToFile, bỏ qua
      
      if (dealTime > maxDealTime) maxDealTime = dealTime;
      
      ulong posId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double comm = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      double swap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      long dealType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      
      double openPrice = 0;
      for (int k = 0; k < total; k++)
      {
         ulong tOpen = HistoryDealGetTicket(k);
         if (HistoryDealGetInteger(tOpen, DEAL_POSITION_ID) == posId &&
             HistoryDealGetInteger(tOpen, DEAL_ENTRY) == DEAL_ENTRY_IN)
         {
            openPrice = HistoryDealGetDouble(tOpen, DEAL_PRICE);
            break;
         }
      }
      
      double netProfit = profit + comm + swap;
      string safeComment = comment;
      StringReplace(safeComment, ",", ";");
      long closeTimeUnix = (long)dealTime;
      string reportLine = StringFormat("0,%I64u,%s,%.5f,%.5f,%.2f,%d,%s,%d",
                         posId, symbol, openPrice, closePrice, netProfit, (int)dealType, safeComment, closeTimeUnix);
      linesToAdd += reportLine + "\r\n";
      added++;
   }
   
   if (added == 0) return;
   
   int h = FileOpen("reports.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if (h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, linesToAdd);
      FileClose(h);
      if (maxDealTime > 0)
         SaveReportAppendedCheckpoint(maxDealTime);
      Print("Appended ", added, " manual closed deal(s) to reports.txt (since ", TimeToString(lastSentTime), ")");
   }
}

//+------------------------------------------------------------------+
//| String Trim Helper                                               |
//+------------------------------------------------------------------+
string StringTrim(string text)
{
   StringTrimLeft(text);
   StringTrimRight(text);
   return text;
}

//+------------------------------------------------------------------+
//| Write confirm to confirm_<accountID>.txt (handshake với Client)  |
//+------------------------------------------------------------------+
void WriteConfirm(string signalId, string status, string orderTicket = "")
{
   string confirmLine = signalId + "," + status;
   if (orderTicket != "") confirmLine += "," + orderTicket;
   
   string confirmFile = "confirm_" + (string)g_accountID + ".txt";
   
   Print("Attempting to write confirm: ", confirmFile, " | Line: ", confirmLine);
   
   ResetLastError();
   int h = FileOpen(confirmFile, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if (h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, confirmLine + "\r\n");
      FileClose(h);
      
      int writeErr = GetLastError();
      if (writeErr == 0 || writeErr == 1) {
         Print("SUCCESS: Confirm written to ", confirmFile, ": ", confirmLine);
      } else {
         Print("WARNING: Confirm written but error code: ", writeErr);
      }
      ResetLastError();
   } else {
      int openErr = GetLastError();
      Print("ERROR: Failed to write confirm to ", confirmFile, " | Error code: ", openErr);
      ResetLastError();
      
      // Thử lại với mode khác (chỉ ghi)
      h = FileOpen(confirmFile, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if (h != INVALID_HANDLE) {
         FileSeek(h, 0, SEEK_END);
         FileWriteString(h, confirmLine + "\r\n");
         FileClose(h);
         Print("SUCCESS (retry): Confirm written to ", confirmFile, ": ", confirmLine);
      } else {
         Print("CRITICAL: Still failed to write confirm after retry. File may be locked or path invalid.");
      }
   }
}

//+------------------------------------------------------------------+
//| Process signal: SIGNAL_ID,ID,TICKET,SYMBOL,TYPE,VOL,SL,TP,PERCENTAGE |
//+------------------------------------------------------------------+
void ProcessSignal(string signal)
{
   string signalId = "";
   
   ResetLastError();
   Print("New signal received: ", signal);
   
   string parts[];
   int count = StringSplit(signal, ',', parts);
   
   int offset = 0;
   
   if (count >= 9) {
      signalId = parts[0];
      offset = 1;
      Print("Signal ID detected: ", signalId, " | Total parts: ", count);
   } else if (count == 8) {
      Print("Old format signal (8 parts), no signal ID");
   } else {
      Print("Invalid signal format (Expected 8-9 parts, got ", count, "): ", signal);
      if (count > 0 && StringFind(parts[0], "_") > 0) {
         signalId = parts[0];
         WriteConfirm(signalId, "ERROR_FORMAT");
         Print("Wrote ERROR_FORMAT confirm for signalId: ", signalId);
      }
      return;
   }
   
   if (GetLastError() != 0) {
      Print("ERROR in StringSplit: ", GetLastError());
      if (signalId != "") {
         WriteConfirm(signalId, "ERROR_PARSE");
         Print("Wrote ERROR_PARSE confirm for signalId: ", signalId);
      }
      ResetLastError();
      return;
   }
   
   if (count < 8 + offset) {
      Print("ERROR: Not enough parts after parsing. Expected at least ", 8 + offset, ", got ", count);
      if (signalId != "") {
         WriteConfirm(signalId, "ERROR_PARSE");
         Print("Wrote ERROR_PARSE confirm for signalId: ", signalId);
      }
      return;
   }
   
   long targetID = StringToInteger(parts[0 + offset]);
   Print("Target ID: ", targetID, " | My ID: ", g_accountID);
   
   if (targetID != g_accountID) {
      Print("Signal ignored. Target ID: ", targetID, " != My ID: ", g_accountID);
      if (signalId != "") {
         WriteConfirm(signalId, "IGNORED");
         Print("Wrote IGNORED confirm for signalId: ", signalId);
      }
      return;
   }

   string ticket = parts[1 + offset];
   string symbol = parts[2 + offset];
   string type = parts[3 + offset];
   double vol = StringToDouble(parts[4 + offset]);
   double slPoints = StringToDouble(parts[5 + offset]);
   double tpPoints = StringToDouble(parts[6 + offset]);
   double signalPercentage = StringToDouble(parts[7 + offset]);
   
   Print("Parsed: Ticket=", ticket, " Symbol=", symbol, " Type=", type, " Vol=", vol, " Pct=", signalPercentage);
   
   double currentLotPercentage = (signalPercentage > 0) ? signalPercentage : LotPercentage;
   
   string mappedSymbol = MapSymbol(symbol);
   if (mappedSymbol == "") {
      Print("ERROR: Symbol not found on this platform: ", symbol);
      if (signalId != "") {
         WriteConfirm(signalId, "ERROR_SYMBOL");
         Print("Wrote ERROR_SYMBOL confirm for signalId: ", signalId);
      }
      return;
   }
   
   if (mappedSymbol != symbol) {
      Print("Symbol mapped: ", symbol, " -> ", mappedSymbol);
   }
   
   if (AutoDetectFillingMode) {
      DetectFillingMode(mappedSymbol);
   }
   
   bool success = false;
   string orderTicket = "";
   
   ResetLastError();
   
   if (type == "CLOSE") {
      success = ClosePosition(mappedSymbol, StringToInteger(ticket));
      Print("ClosePosition result: ", success ? "SUCCESS" : "FAILED");
   } else if (type == "CLOSE_ALL") {
      // Bản EAnew: chỉ đóng các lệnh do bot tạo (comment xBot| hoặc bot-...),
      // không động vào lệnh đánh tay (comment khác / rỗng). Có retry nội bộ.
      int closed = CloseAllBotPositionsSmart();
      success = true; // Kể cả đã đóng trước đó (0 lệnh), xem như xử lý CLOSE_ALL thành công
      orderTicket = IntegerToString(closed) + "_closed";
      Print("CloseAllBotPositionsSmart result: closed ", closed, " bot position(s).");
   } else if (type == "BUY" || type == "SELL") {
      string botServerId = (count >= 10) ? StringTrim(parts[9]) : "";
      orderTicket = ExecuteTrade(mappedSymbol, type, vol, slPoints, tpPoints, currentLotPercentage, ticket, botServerId);
      success = (orderTicket != "");
      Print("ExecuteTrade result: ", success ? "SUCCESS" : "FAILED", " Ticket: ", orderTicket);
   } else {
      Print("ERROR: Unknown order type: ", type);
      if (signalId != "") {
         WriteConfirm(signalId, "ERROR_TYPE");
         Print("Wrote ERROR_TYPE confirm for signalId: ", signalId);
      }
      return;
   }
   
   int execErr = GetLastError();
   if (execErr != 0 && execErr != 1) {
      Print("ERROR after execution: ", execErr);
      if (signalId != "" && !success) {
         WriteConfirm(signalId, "ERROR_EXEC");
         Print("Wrote ERROR_EXEC confirm for signalId: ", signalId);
         ResetLastError();
         return;
      }
      ResetLastError();
   }
   
   if (signalId != "") {
      if (success) {
         WriteConfirm(signalId, "OK", orderTicket);
         Print("Signal confirmed: ", signalId, " Order: ", orderTicket);
      } else {
         WriteConfirm(signalId, "FAILED");
         Print("Signal failed: ", signalId);
      }
   } else {
      Print("Signal processed (old format, no confirm): ", signal);
   }
}

//+------------------------------------------------------------------+
//| Close ALL BOT positions only (smart ordering + retry)            |
//| - Chỉ đóng position có comment bắt đầu "xBot|" hoặc "bot-"       |
//| - Giữ nguyên lệnh đánh tay (comment khác / rỗng)                 |
//+------------------------------------------------------------------+
int CloseAllBotPositionsSmart()
{
   // Mỗi pass: quét lại toàn bộ, lấy các lệnh do bot tạo (comment),
   // sắp xếp theo ưu tiên rồi đóng. Lặp vài lần để đảm bảo đã đóng hết.

   struct PosInfo
   {
      ulong   ticket;
      string  symbol;
      double  volume;
      double  profit;
      int     type;
      string  comment;
   };

   int totalClosed = 0;
   const int MAX_PASS = 200;
   int stagnantPass = 0;

   for (int pass = 0; pass < MAX_PASS; pass++)
   {
      int botRemainBefore = CountBotPositions();
      if (botRemainBefore == 0)
      {
         if (pass == 0)
            Print("No bot positions to close.");
         break;
      }
      int total = PositionsTotal();

      PosInfo arr[];
      ArrayResize(arr, total);
      int count = 0;

      for (int i = 0; i < PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if (!PositionSelectByTicket(ticket))
            continue;

         string cmt = PositionGetString(POSITION_COMMENT);
         bool isBot = IsBotComment(cmt);
         if (!isBot)
            continue; // bỏ qua lệnh đánh tay

         arr[count].ticket  = ticket;
         arr[count].symbol  = PositionGetString(POSITION_SYMBOL);
         arr[count].volume  = PositionGetDouble(POSITION_VOLUME);
         arr[count].profit  = PositionGetDouble(POSITION_PROFIT);
         arr[count].type    = (int)PositionGetInteger(POSITION_TYPE);
         arr[count].comment = cmt;
         count++;
      }

      if (count == 0)
      {
         if (pass == 0)
            Print("No bot positions to close (only manual trades exist).");
         break;
      }

      ArrayResize(arr, count);

      // Sort: dương trước (profit > 0), trong nhóm dương: profit giảm dần;
      // trong nhóm âm: profit giảm dần (ít lỗ trước).
      for (int i = 0; i < count - 1; i++)
      {
         for (int j = i + 1; j < count; j++)
         {
            bool aiPos = (arr[i].profit > 0);
            bool ajPos = (arr[j].profit > 0);

            bool shouldSwap = false;

            if (aiPos != ajPos)
            {
               if (!aiPos && ajPos) shouldSwap = true; // dương đứng trước âm
            }
            else
            {
               if (arr[j].profit > arr[i].profit)
                  shouldSwap = true; // cùng dấu: profit lớn trước
            }

            if (shouldSwap)
            {
               PosInfo tmp = arr[i];
               arr[i] = arr[j];
               arr[j] = tmp;
            }
         }
      }

      int closedThisPass = 0;

      for (int k = 0; k < count; k++)
      {
         ulong ticket = arr[k].ticket;
         if (!PositionSelectByTicket(ticket))
            continue;

         string sym    = PositionGetString(POSITION_SYMBOL);
         double pf     = PositionGetDouble(POSITION_PROFIT);
         string cmt    = PositionGetString(POSITION_COMMENT);

         Print("Closing BOT position ticket ", ticket,
               " (", sym, "), P/L=", DoubleToString(pf, 2),
               ", comment=", cmt);

         if (trade.PositionClose(ticket))
         {
            closedThisPass++;
         }
         else
         {
            Print("Close FAILED ", ticket, " ", trade.ResultRetcodeDescription());
         }
      }

      if (closedThisPass == 0) stagnantPass++;
      else stagnantPass = 0;

      totalClosed += closedThisPass;
      int botRemainAfter = CountBotPositions();
      if (botRemainAfter == 0) break;
      if (stagnantPass >= 20)
      {
         Print("CloseAllBotPositionsSmart stalled with ", botRemainAfter, " bot position(s) still open.");
         break;
      }

      // Nhường CPU một chút để server update trạng thái trước khi pass tiếp theo
      Sleep(100);
   }

   if (totalClosed > 0)
      Print("🚨 Closed ", totalClosed, " BOT position(s). Manual trades left untouched.");
   else
      Print("No BOT positions were closed (maybe already closed).");

   return totalClosed;
}

//+------------------------------------------------------------------+
//| Close Position                                                   |
//+------------------------------------------------------------------+
bool ClosePosition(string symbol, ulong masterTicket)
{
   const int MAX_PASS = 200;
   int stagnantPass = 0;
   int totalClosed = 0;

   for (int pass = 0; pass < MAX_PASS; pass++)
   {
      int matchCount = 0;
      int closedThisPass = 0;

      for (int i = PositionsTotal() - 1; i >= 0; i--) {
         ulong ticket = PositionGetTicket(i);
         if (!PositionSelectByTicket(ticket)) continue;
         if (PositionGetString(POSITION_SYMBOL) != symbol) continue;

         string comment = PositionGetString(POSITION_COMMENT);
         if (!IsMatchMasterTicketComment(comment, masterTicket)) continue;
         matchCount++;

         Print("Closing position: ", ticket, " ", symbol, " matched with Master: ", masterTicket);
         if (trade.PositionClose(ticket)) {
            Print("Position closed. Queuing report...");
            int size = ArraySize(g_reports);
            ArrayResize(g_reports, size + 1);
            g_reports[size].masterTicket = masterTicket;
            g_reports[size].slaveTicket = ticket;
            g_reports[size].closeTime = TimeCurrent();
            g_reports[size].symbol = symbol;
            g_reports[size].comment = comment;
            closedThisPass++;
            totalClosed++;
         } else {
            Print("Close failed: ", trade.ResultRetcodeDescription());
         }
      }

      if (matchCount == 0)
      {
         if (totalClosed == 0) Print("Position not found (may already closed): ", symbol, " Master: ", masterTicket);
         else Print("ClosePosition done. Closed ", totalClosed, " position(s) for Master: ", masterTicket);
         return true;
      }

      if (closedThisPass == 0) stagnantPass++;
      else stagnantPass = 0;
      if (stagnantPass >= 20)
      {
         Print("ClosePosition stalled, still has position(s) for Master: ", masterTicket);
         return false;
      }
      Sleep(100);
   }

   Print("ClosePosition timeout (max pass reached) for Master: ", masterTicket);
   return false;
}

//+------------------------------------------------------------------+
//| Execute Trade                                                    |
//+------------------------------------------------------------------+
string ExecuteTrade(string symbol, string type, double vol, double slPoints, double tpPoints, double pct, string ticket, string botServerId = "")
{
   string expectedXBot = "xBot|" + ticket;
   string expectedBot = (botServerId != "") ? ("bot-" + botServerId + "|" + ticket) : "";
   for (int i = 0; i < PositionsTotal(); i++) {
      ulong posTicket = PositionGetTicket(i);
      if (PositionSelectByTicket(posTicket)) {
         string c = PositionGetString(POSITION_COMMENT);
         if (c == expectedXBot || (expectedBot != "" && c == expectedBot) ||
             (StringFind(c, "bot-") == 0 && StringFind(c, "|" + ticket) >= 0)) {
            Print("Master Ticket ", ticket, " is already open (Slave Ticket: ", posTicket, "). Skipping double entry.");
            return IntegerToString(posTicket);
         }
      }
   }

   string openBlockReason = "";
   if (!CanOpenNow(openBlockReason))
   {
      Print("Open skipped for ticket ", ticket, ": ", openBlockReason);
      return "";
   }

   ENUM_POSITION_TYPE posType = (type == "BUY") ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   ENUM_ORDER_TYPE orderType = (type == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   double price = (type == "BUY") ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   double slPrice = 0;
   double tpPrice = 0;
   
   if (slPoints > 0) {
      slPrice = (type == "BUY") ? price - slPoints * point : price + slPoints * point;
      slPrice = NormalizeDouble(slPrice, digits);
   }
   
   if (tpPoints > 0) {
      tpPrice = (type == "BUY") ? price + tpPoints * point : price - tpPoints * point;
      tpPrice = NormalizeDouble(tpPrice, digits);
   }
   
   double finalVol = NormalizeDouble(vol, 2);
   if (finalVol <= 0)
   {
      Print("Invalid final volume from client: ", vol, " (pct=", pct, ")");
      return "";
   }
   Print("Using final volume from client: ", finalVol);
   
   string comment = (botServerId != "") ? ("bot-" + botServerId + "|" + ticket) : ("xBot|" + ticket);
   
   const int MAX_OPEN_RETRY = 5;
   const int RETRY_DELAY_MS = 200;
   for (int attempt = 1; attempt <= MAX_OPEN_RETRY; attempt++)
   {
      if (trade.PositionOpen(symbol, orderType, finalVol, price, slPrice, tpPrice, comment)) {
         ulong orderTicket = trade.ResultOrder();
         MarkOpenSuccess();
         Print("Trade executed successfully. Ticket: ", orderTicket, " attempt=", attempt, "/", MAX_OPEN_RETRY);
         return IntegerToString(orderTicket);
      }
      Print("Trade failed attempt ", attempt, "/", MAX_OPEN_RETRY, ": ", trade.ResultRetcodeDescription());
      if (attempt < MAX_OPEN_RETRY) {
         Sleep(RETRY_DELAY_MS);
         price = (type == "BUY") ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
      }
   }
   return "";
}

//+------------------------------------------------------------------+
//| Map Symbol (Handles Standard <-> Cent and suffixes)              |
//+------------------------------------------------------------------+
string MapSymbol(string source)
{
   if (SymbolCheck(source)) return source;
   
   string fix[] = {".m", ".pro", ".x", "m", "pro", "c", ".c", "i"};
   
   string cleaned = source;
   for (int i = 0; i < ArraySize(fix); i++) {
      if (StringLen(cleaned) > StringLen(fix[i])) {
         int pos = StringFind(cleaned, fix[i], StringLen(cleaned) - StringLen(fix[i]));
         if (pos >= 0) {
            string trial = StringSubstr(cleaned, 0, pos);
            if (SymbolCheck(trial)) return trial;
            cleaned = trial;
         }
      }
      if (StringFind(cleaned, fix[i]) == 0) {
         string trial = StringSubstr(cleaned, StringLen(fix[i]));
         if (SymbolCheck(trial)) return trial;
         cleaned = trial;
      }
   }
   
   for (int i = 0; i < ArraySize(fix); i++) {
      string trial = cleaned + fix[i];
      if (SymbolCheck(trial)) return trial;
   }
   
   return "";
}

bool SymbolCheck(string sym)
{
   ResetLastError();
   if (SymbolInfoInteger(sym, SYMBOL_VISIBLE)) return true;
   if (SymbolSelect(sym, true)) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Detect Filling Mode                                              |
//+------------------------------------------------------------------+
void DetectFillingMode(string symbol)
{
   int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   
   if ((filling & SYMBOL_FILLING_FOK) != 0) {
      g_fillingMode = ORDER_FILLING_FOK;
   } else if ((filling & SYMBOL_FILLING_IOC) != 0) {
      g_fillingMode = ORDER_FILLING_IOC;
   } else {
      g_fillingMode = ORDER_FILLING_RETURN;
   }
   
   trade.SetTypeFilling(g_fillingMode);
}

