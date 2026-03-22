//+------------------------------------------------------------------+
//|                                                      xBotMaster.mq5 |
//|                        Copy Trade Master EA (HTTP Sender)         |
//|                        Run on VPS - Sends to localhost            |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copy Trade System"
#property link      ""
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| Wininet Library (Embedded)                                       |
//+------------------------------------------------------------------+
#import "wininet.dll"
   int InternetOpenW(string, int, string, string, int);
   int InternetConnectW(int, string, ushort, string, string, int, int, int);
   int HttpOpenRequestW(int, string, string, string, string, string, int, int);
   int HttpSendRequestW(int, string, int, uchar &[], int);
   int InternetCloseHandle(int);
   int InternetReadFile(int, uchar &[], int, int &);
   int InternetQueryDataAvailable(int, int &);
#import

#import "kernel32.dll"
   int GetLastError();  // Win32 last error (sau khi WinINet thất bại)
#import

// Constants for wininet.dll
#define INTERNET_OPEN_TYPE_DIRECT    1
#define INTERNET_DEFAULT_HTTP_PORT   80
#define INTERNET_SERVICE_HTTP        3
#define INTERNET_FLAG_RELOAD         0x80000000
#define INTERNET_FLAG_NO_CACHE_WRITE 0x04000000

// Global variables for Wininet
int g_hInternet = 0;
int g_hConnect = 0;
bool g_wininetInitialized = false;
datetime g_lastHttpErrorLog = 0;  // Throttle log lỗi — không spam mỗi giây

//+------------------------------------------------------------------+
//| Mô tả lỗi WinINet thường gặp (Win32 error code)                 |
//+------------------------------------------------------------------+
string WinInetErrorDesc(int code)
{
   switch(code) {
      case 0:           return "Unknown (0) — Kiểm tra Bot server đã mở chưa";
      case 12002:       return "Timeout — Server không phản hồi";
      case 12007:       return "Tên miền/IP không phân giải được";
      case 12029:       return "Không kết nối được — Server tắt hoặc firewall chặn";
      case 12030:       return "Kết nối bị ngắt";
      case 12111:       return "Kết nối bị đóng bởi server";
      case 12152:       return "Phản hồi HTTP lỗi từ server";
      case 12175:       return "Lỗi bảo mật (SSL/certificate)";
      default:          return "Mã " + IntegerToString(code);
   }
}

//+------------------------------------------------------------------+
//| Initialize Wininet connection                                    |
//+------------------------------------------------------------------+
bool InitWininet(string serverIP, ushort serverPort)
{
   if (g_wininetInitialized && g_hConnect != 0) {
      return true;
   }
   
   // Initialize Internet connection
   string userAgent = "MQL5 Master EA";
   g_hInternet = InternetOpenW(userAgent, INTERNET_OPEN_TYPE_DIRECT, "", "", 0);
   
   if (g_hInternet == 0) {
      Print("InternetOpenW failed");
      return false;
   }
   
   // Connect to server
   g_hConnect = InternetConnectW(
      g_hInternet,
      serverIP,
      serverPort,
      "",
      "",
      INTERNET_SERVICE_HTTP,
      0,
      0
   );
   
   if (g_hConnect == 0) {
      Print("InternetConnectW failed to: ", serverIP, ":", serverPort);
      InternetCloseHandle(g_hInternet);
      g_hInternet = 0;
      return false;
   }
   
   g_wininetInitialized = true;
   Print("Wininet initialized. Connected to: ", serverIP, ":", serverPort);
   return true;
}

//+------------------------------------------------------------------+
//| Cleanup Wininet                                                  |
//+------------------------------------------------------------------+
void CleanupWininet()
{
   if (g_hConnect != 0) {
      InternetCloseHandle(g_hConnect);
      g_hConnect = 0;
   }
   
   if (g_hInternet != 0) {
      InternetCloseHandle(g_hInternet);
      g_hInternet = 0;
   }
   
   g_wininetInitialized = false;
   Print("Wininet cleaned up");
}

//+------------------------------------------------------------------+
//| Send HTTP POST request                                           |
//+------------------------------------------------------------------+
bool SendHttpPost(string path, string data)
{
   if (g_hConnect == 0) {
      Print("Not connected to server");
      return false;
   }
   
   // Open HTTP request
   int hRequest = HttpOpenRequestW(
      g_hConnect,
      "POST",
      path,
      "HTTP/1.1",
      "",
      "",
      (int)((uint)INTERNET_FLAG_RELOAD | (uint)INTERNET_FLAG_NO_CACHE_WRITE),
      0
   );
   
   if (hRequest == 0) {
      Print("HttpOpenRequestW failed");
      return false;
   }
   
   // Convert data to bytes (UTF-8) — Content-Length phải là byte length, không phải số ký tự
   uchar dataBytes[];
   int dataLen = StringToCharArray(data, dataBytes, 0, WHOLE_ARRAY, CP_UTF8) - 1; // -1 to exclude null terminator
   
   if (dataLen <= 0) {
      Print("Invalid data length");
      InternetCloseHandle(hRequest);
      return false;
   }
   
   // Prepare headers — Content-Length theo byte thực tế
   string headers = "Content-Type: text/plain; charset=utf-8\r\n";
   headers += "Content-Length: " + IntegerToString(dataLen) + "\r\n";
   
   // Send request with headers and data
   int result = HttpSendRequestW(hRequest, headers, StringLen(headers), dataBytes, dataLen);
   
   bool success = (result != 0);
   
   if (success) {
      // Read response to get server response
      int bytesAvailable = 0;
      string responseText = "";
      if (InternetQueryDataAvailable(hRequest, bytesAvailable) != 0 && bytesAvailable > 0) {
         uchar responseBuffer[];
         ArrayResize(responseBuffer, bytesAvailable);
         int bytesRead = 0;
         if (InternetReadFile(hRequest, responseBuffer, bytesAvailable, bytesRead) != 0 && bytesRead > 0) {
            responseText = CharArrayToString(responseBuffer, 0, bytesRead, CP_UTF8);
         }
      }
      Print("HTTP POST sent. Response: ", responseText);
   } else {
      // Lấy mã lỗi Win32 (GetLastError từ kernel32)
      int winErr = GetLastError();
      string errMsg = WinInetErrorDesc(winErr);
      // Chỉ log tối đa mỗi 60 giây để tránh spam
      if (TimeCurrent() - g_lastHttpErrorLog >= 60) {
         g_lastHttpErrorLog = TimeCurrent();
         Print("HttpSendRequestW failed. Win32 error: ", winErr, " — ", errMsg);
         Print("  → Bot server phải chạy trên ", TargetIP, ":", TargetPort, " (xBotServer). Mở app Bot rồi bấm Start.");
      }
   }
   
   // Close request handle
   InternetCloseHandle(hRequest);
   
   return success;
}

//+------------------------------------------------------------------+
//| Check if Wininet is initialized                                  |
//+------------------------------------------------------------------+
bool IsWininetInitialized()
{
   return (g_wininetInitialized && g_hConnect != 0);
}

//--- Input parameters (EA và Bot cùng server — gửi localhost, Bot HTTP lắng nghe 1995)
input string   TargetIP = "127.0.0.1";   // IP Bot server (cùng máy = 127.0.0.1)
input ushort   TargetPort = 1995;        // Cổng HTTP Bot (POST /update), không dùng 80

// File template: EA ghi vào Common/Files (MQL5 cho phép), Bot đọc từ %APPDATA%\MetaQuotes\Terminal\Common\Files\
#define BALANCE_TEMPLATE_FILE "source_balance.txt"
#define BALANCE_FILE_USE_COMMON 1  // FILE_COMMON = ghi vào Terminal\Common\Files

//--- Global variables
ulong g_processedTickets[];  // Track already processed tickets
datetime g_lastBalanceSent = 0;
datetime g_lastBalanceFileWritten = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize Wininet connection to local server
   if (!InitWininet(TargetIP, TargetPort)) {
      Print("Failed to initialize Wininet connection");
      return INIT_FAILED;
   }
   
   Print("xBotMaster EA initialized");
   Print("Target: ", TargetIP, ":", TargetPort, " (Bot HTTP — cùng server, không ra ngoài mạng)");
   
   // Send initial balance
   SendBalance();
   // Tạo/ghi file template balance ngay khi khởi động — Bot đọc file này
   WriteBalanceToFile();
   g_lastBalanceFileWritten = TimeCurrent();
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick function                                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   // Gửi balance qua HTTP mỗi 60 giây
   if (TimeCurrent() - g_lastBalanceSent > 60) {
      SendBalance();
   }
   // Ghi balance ra file template mỗi 30 giây (Bot server đọc file này)
   if (TimeCurrent() - g_lastBalanceFileWritten >= 30) {
      WriteBalanceToFile();
      g_lastBalanceFileWritten = TimeCurrent();
   }
}

void SendBalance()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if (SendHttpPost("/balance", DoubleToString(balance, 2))) {
      g_lastBalanceSent = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Ghi balance ra file template — Bot server đọc file này mỗi 20s   |
//+------------------------------------------------------------------+
void WriteBalanceToFile()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   int flags = FILE_WRITE|FILE_TXT|FILE_ANSI;
   #ifdef BALANCE_FILE_USE_COMMON
   flags |= FILE_COMMON;  // Ghi vào Terminal\Common\Files — tránh lỗi 5002 (không cho ghi ra ổ C:\ tùy ý)
   #endif
   int h = FileOpen(BALANCE_TEMPLATE_FILE, flags);
   if (h != INVALID_HANDLE) {
      FileWriteString(h, DoubleToString(balance, 2));
      FileClose(h);
      // Log để biết EA đã tạo/cập nhật file — lần đầu + mỗi 5 phút tránh spam
      static bool s_firstSuccess = true;
      static datetime s_lastSuccessLog = 0;
      if (s_firstSuccess || (TimeCurrent() - s_lastSuccessLog >= 300)) {
         Print("WriteBalanceToFile: Đã ghi file balance — ", BALANCE_TEMPLATE_FILE,
               " (Terminal\\Common\\Files). Balance: ", DoubleToString(balance, 2));
         s_firstSuccess = false;
         s_lastSuccessLog = TimeCurrent();
      }
   } else {
      static datetime lastErr = 0;
      if (TimeCurrent() - lastErr > 300) {
         Print("WriteBalanceToFile failed: ", BALANCE_TEMPLATE_FILE, " err ", GetLastError(),
               " — Kiểm tra quyền ghi thư mục Common/Files hoặc chạy MT5 với quyền bình thường.");
         lastErr = TimeCurrent();
      }
      ResetLastError();
   }
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   CleanupWininet();
   Print("xBotMaster EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Trade transaction event handler                                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   // Only process deal events (new trades)
   if (trans.type != TRADE_TRANSACTION_DEAL_ADD) {
      return;
   }
   
   // Get deal ticket
   ulong dealTicket = trans.deal;
   if (dealTicket == 0) {
      return;
   }
   
   // Check if already processed
   if (IsTicketProcessed(dealTicket)) {
      return;
   }
   
   // Get deal information
   if (!HistoryDealSelect(dealTicket)) {
      return;
   }
   
   // Skip if it's a copy trade (to avoid loops)
   string dealComment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
   if (StringFind(dealComment, "CopyTrade") >= 0) {
      return;
   }
   
   // Process both entry (OPEN) and exit (CLOSE) deals
   ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   
   // Get deal information
   string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   long dealType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   ulong positionId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   
   string orderType = "";
   ulong ticketToSend = 0;
   double sl = 0;
   double tp = 0;
   
   // Handle CLOSE signal (DEAL_ENTRY_OUT)
   if (dealEntry == DEAL_ENTRY_OUT) {
      // For CLOSE, positionId is the position ticket that was closed
      // In MT5, positionId is the same as position ticket for most brokers
      if (positionId > 0) {
         ticketToSend = positionId;
      } else {
         // Fallback: use deal ticket if positionId not available
         ticketToSend = dealTicket;
      }
      
      orderType = "CLOSE";
      // For CLOSE signal: Volume, SL, TP are not needed (set to 0)
      volume = 0;
      sl = 0;
      tp = 0;
   }
   // Handle OPEN signal (DEAL_ENTRY_IN)
   else if (dealEntry == DEAL_ENTRY_IN) {
      // Determine order type
      if (dealType == DEAL_TYPE_BUY) {
         orderType = "BUY";
      } else if (dealType == DEAL_TYPE_SELL) {
         orderType = "SELL";
      } else {
         return;  // Unknown deal type
      }
      
      // Get position information for SL/TP
      ulong positionTicket = 0;
      
      if (positionId > 0 && PositionSelectByTicket(positionId)) {
         positionTicket = PositionGetInteger(POSITION_TICKET);
         sl = PositionGetDouble(POSITION_SL);
         tp = PositionGetDouble(POSITION_TP);
         double posPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         long posType = PositionGetInteger(POSITION_TYPE);
         
         // Convert SL/TP to points offset
         if (sl > 0) {
            if (posType == POSITION_TYPE_BUY) {
               sl = (posPrice - sl) / SymbolInfoDouble(symbol, SYMBOL_POINT);
            } else {
               sl = (sl - posPrice) / SymbolInfoDouble(symbol, SYMBOL_POINT);
            }
         }
         
         if (tp > 0) {
            if (posType == POSITION_TYPE_BUY) {
               tp = (tp - posPrice) / SymbolInfoDouble(symbol, SYMBOL_POINT);
            } else {
               tp = (posPrice - tp) / SymbolInfoDouble(symbol, SYMBOL_POINT);
            }
         }
      }
      
      // Use position ticket or deal ticket
      ticketToSend = (positionTicket > 0) ? positionTicket : dealTicket;
   } else {
      // Unknown entry type, skip
      return;
   }
   
   // Build signal: Ticket,Symbol,Type,Volume,SL,TP
   string signal = IntegerToString(ticketToSend) + "," + 
            symbol + "," + 
            orderType + "," + 
            DoubleToString(volume, 2) + "," + 
            DoubleToString(sl, 0) + "," + 
            DoubleToString(tp, 0);
   
   // Gửi balance trước mỗi signal để Bot luôn có balance mới nhất khi client kết nối / tính Auto %
   SendBalance();
   
   // Send signal
   if (StringLen(signal) > 0) {
      Print("Attempting to send signal: ", signal);
      if (SendHttpPost("/update", signal)) {
         Print("Signal sent successfully: ", signal);
         AddProcessedTicket(dealTicket);
      } else {
         Print("Failed to send signal: ", signal, " - Check server is running on ", TargetIP, ":", TargetPort);
      }
   }
}

//+------------------------------------------------------------------+
//| Check if ticket was already processed                            |
//+------------------------------------------------------------------+
bool IsTicketProcessed(ulong ticket)
{
   for (int i = 0; i < ArraySize(g_processedTickets); i++) {
      if (g_processedTickets[i] == ticket) {
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Add ticket to processed list                                    |
//+------------------------------------------------------------------+
void AddProcessedTicket(ulong ticket)
{
   int size = ArraySize(g_processedTickets);
   ArrayResize(g_processedTickets, size + 1);
   g_processedTickets[size] = ticket;
}
