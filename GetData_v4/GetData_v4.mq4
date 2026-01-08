//+------------------------------------------------------------------+
//|                                              Get_Data_V3.mq4     |
//|                     Send ALL symbols with trade_mode             |
//+------------------------------------------------------------------+
#property copyright "9/10/2025 - Modified to send all symbols"
#property version   "Get_Data V4"
#property strict

input int SendInterval = 1; // Send interval (seconds)
input string glbStringFilePath = "web_url"; // File .txt chứa URL
input bool SendOnlyOpenMarkets = false; // Chỉ gửi sản phẩm đang mở (false = gửi tất cả)
input bool SendOnlyCurrentSymbol = false; // Chỉ gửi symbol của chart hiện tại
input int HistoricalCandles = 100; // Số nến lịch sử gửi lần đầu (50-200)
string WebServerURL = ""; // URL sẽ được đọc từ file
datetime lastSendTime = 0;

// Track symbols đã gửi historical data (chỉ gửi 1 lần)
bool historicalDataSent[];
string historicalDataSymbols[];
int historicalDataCount = 0;

// Struct for trade sessions
struct Section_Trade
{
    datetime str_start_time;
    datetime str_finish_time;
};
struct Section_Trade_Ngay_Trong_Tuan
{
    Section_Trade str_arr_Section_Trade_Moi_Ngay[10];
    int str_Tong_Section_Trade_Moi_Ngay;
};
Section_Trade_Ngay_Trong_Tuan glb_Section_Trade_Array[10];

struct TradeSignal {
    string action;
    string symbol;
    string side;
    string comment;
    double volume;
    double sl_points;
    double tp_points;
    int    max_slippage;
    int  ticket;
};

string global_last_response = "";

string EscapeJsonString(string value)
{
    string result = value;
    StringReplace(result, "\\", "\\\\");
    StringReplace(result, "\"", "\\\"");
    return result;
}

string GetSymbolGroupPath(string symbol)
{
    string group_path = "";
#ifdef SYMBOL_PATH
    string tmp = "";
    if(SymbolInfoString(symbol, SYMBOL_PATH, tmp) && StringLen(tmp) > 0)
        group_path = tmp;
#endif

#ifdef SYMBOL_SECTOR
    if(group_path == "")
    {
        string sector = "";
        if(SymbolInfoString(symbol, SYMBOL_SECTOR, sector) && StringLen(sector) > 0)
            group_path = sector;
    }
#endif

    return group_path;
}

// Helper functions for historical data tracking
bool HasSentHistoricalData(string symbol)
{
    for(int i = 0; i < historicalDataCount; i++)
    {
        if(historicalDataSymbols[i] == symbol)
            return historicalDataSent[i];
    }
    return false;
}

void MarkHistoricalDataSent(string symbol)
{
    // Tìm symbol trong list
    for(int i = 0; i < historicalDataCount; i++)
    {
        if(historicalDataSymbols[i] == symbol)
        {
            historicalDataSent[i] = true;
            return;
        }
    }

    // Nếu chưa có, thêm mới
    ArrayResize(historicalDataSymbols, historicalDataCount + 1);
    ArrayResize(historicalDataSent, historicalDataCount + 1);
    historicalDataSymbols[historicalDataCount] = symbol;
    historicalDataSent[historicalDataCount] = true;
    historicalDataCount++;
}

void ResetHistoricalDataTracking()
{
    // Reset tất cả tracking (sẽ gửi lại historical data cho tất cả symbols)
    ArrayResize(historicalDataSymbols, 0);
    ArrayResize(historicalDataSent, 0);
    historicalDataCount = 0;
    Print("Reset historical data tracking - Will resend historical candles");
}

// Hàm lấy historical candles data cho 1 symbol
string GetHistoricalCandlesJSON(string symbol, int count)
{
    string json = "[";
    bool first = true;

    // Lấy historical M1 candles (từ cũ đến mới)
    for(int i = count - 1; i >= 0; i--)
    {
        double open = iOpen(symbol, PERIOD_M1, i);
        double high = iHigh(symbol, PERIOD_M1, i);
        double low = iLow(symbol, PERIOD_M1, i);
        double close = iClose(symbol, PERIOD_M1, i);
        datetime time = iTime(symbol, PERIOD_M1, i);

        if(time == 0) continue; // Skip nếu không có dữ liệu

        if(!first)
            json += ",";

        // Format: [timestamp, open, high, low, close]
        json += StringFormat("[%lld,%.5f,%.5f,%.5f,%.5f]",
            (long)time,
            open,
            high,
            low,
            close
        );

        first = false;
    }

    json += "]";
    return json;
}

//============================================================
// Hàm đọc URL từ file
bool ReadWebServerURL()
{
    int file_handle = FileOpen(glbStringFilePath + ".txt", FILE_READ | FILE_TXT | FILE_SHARE_READ);
    if(file_handle == INVALID_HANDLE)
    {
        Print("Loi: Khong mo duoc file ", glbStringFilePath, ".txt ERR: ", GetLastError());
        return false;
    }
    WebServerURL = FileReadString(file_handle);
    StringTrimLeft(WebServerURL);
    StringTrimRight(WebServerURL);

    FileClose(file_handle);
    if(WebServerURL == "")
    {
        Print("Loi: Thieu cau hinh trong file txt ", glbStringFilePath, ".txt");
        return false;
    }

    if(StringSubstr(WebServerURL, StringLen(WebServerURL) - 1) != "/")
        WebServerURL += "/";

    return true;
}

//============================================================
// Hàm gửi dữ liệu tới server
bool SendDataToWeb(string method, string url, string jsonData = "")
{
    string headers = "Content-Type: application/json\r\n";
    char post[], result[];
    int timeout = 5000;
    string resultHeaders;

    if(jsonData != "")
        StringToCharArray(jsonData, post, 0, StringLen(jsonData));

    int res = WebRequest(
        method,
        url,
        headers,
        timeout,
        post,
        result,
        resultHeaders
    );

    if(res == -1)
    {
        int error = GetLastError();
        if(error != 0)
        {
            Print("WebRequest Error: ", error, " for URL: ", url);
            if(error == 4014)
                Print("CHECK: WebRequest URL phai duoc them vao Tools -> Options -> Expert Advisors -> Allow WebRequest");
        }
        return false;
    }

    return true;
}

//============================================================
// ✨ MỚI: Hàm lấy dữ liệu Market Watch - GỬI TẤT CẢ SYMBOLS KÈM TRADE_MODE
string GetMarketWatchData()
{
    if(!ReadWebServerURL()) return "";

    string jsonData = "{";
    int totalSymbols = SymbolsTotal(true);
    bool first = true;
    string symbolsData = "[";
    string brokerServer = AccountServer();

    for(int i = 0; i < totalSymbols; i++)
    {
        string symbol = SymbolName(i, true);
        
        // Nếu SendOnlyCurrentSymbol = true và symbol != Symbol() hiện tại thì skip
        if(SendOnlyCurrentSymbol && symbol != Symbol()) continue;
        
        double bid = MarketInfo(symbol, MODE_BID);
        double ask = MarketInfo(symbol, MODE_ASK);
        int digits = (int)MarketInfo(symbol, MODE_DIGITS);
        double point_value = MarketInfo(symbol, MODE_POINT);
        
        if(bid <= 0 || ask <= 0) continue;
        
        bool isOpen = FunCheckMartKetOpenMotCapTien(symbol);

        // ✨ THAY ĐỔI CHÍNH: Lấy SYMBOL_TRADE_MODE và KHÔNG BỎ QUA bất kỳ symbol nào
        ENUM_SYMBOL_TRADE_MODE trade_mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
        string trade_mode_str = "";

        switch(trade_mode)
        {
            case SYMBOL_TRADE_MODE_DISABLED:     trade_mode_str = "DISABLED"; break;
            case SYMBOL_TRADE_MODE_LONGONLY:     trade_mode_str = "LONGONLY"; break;
            case SYMBOL_TRADE_MODE_SHORTONLY:    trade_mode_str = "SHORTONLY"; break;
            case SYMBOL_TRADE_MODE_CLOSEONLY:    trade_mode_str = "CLOSEONLY"; break;
            case SYMBOL_TRADE_MODE_FULL:         trade_mode_str = "FULL"; break;
            default:                              trade_mode_str = "UNKNOWN"; break;
        }

        // ✅ BỎ LOGIC FILTER - GỬI TẤT CẢ SYMBOLS
        // Trước đây: if(trade_mode != FULL && ...) continue;
        // Bây giờ: GỬI HẾT, Python sẽ lọc
        
        // Lấy OHLC của nến M1 trước đó và nến hiện tại
        double prev_open = iOpen(symbol, PERIOD_M1, 1);
        double prev_high = iHigh(symbol, PERIOD_M1, 1);
        double prev_low = iLow(symbol, PERIOD_M1, 1);
        double prev_close = iClose(symbol, PERIOD_M1, 1);
        
        double current_open = iOpen(symbol, PERIOD_M1, 0);
        double current_high = iHigh(symbol, PERIOD_M1, 0);
        double current_low = iLow(symbol, PERIOD_M1, 0);
        double current_close = iClose(symbol, PERIOD_M1, 0);
        
        // Lấy thông tin trade sessions
        string tradeSessions = GetTradeSessionsJSON(symbol);

        string groupPathRaw = GetSymbolGroupPath(symbol);
        string groupPathJson = EscapeJsonString(groupPathRaw);

        // Kiểm tra xem đã gửi historical data chưa
        bool needsHistorical = !HasSentHistoricalData(symbol);
        string historicalJSON = "";
        
        if(needsHistorical)
        {
            historicalJSON = GetHistoricalCandlesJSON(symbol, HistoricalCandles);
            MarkHistoricalDataSent(symbol);
        }

        // ✨ THÊM FIELD trade_mode VÀO JSON
        string symbolData = StringFormat(
            "{\"symbol\":\"%s\",\"group\":\"%s\",\"trade_mode\":\"%s\",\"bid\":%.5f,\"ask\":%.5f,\"digits\":%d,\"points\":%.5f,\"isOpen\":%s," +
            "\"prev_ohlc\":{\"open\":%.5f,\"high\":%.5f,\"low\":%.5f,\"close\":%.5f}," +
            "\"current_ohlc\":{\"open\":%.5f,\"high\":%.5f,\"low\":%.5f,\"close\":%.5f}," +
            "\"trade_sessions\":%s",
            symbol, groupPathJson, trade_mode_str,
            bid, ask, digits, point_value,
            isOpen ? "true" : "false",
            prev_open, prev_high, prev_low, prev_close,
            current_open, current_high, current_low, current_close,
            tradeSessions
        );
        
        // Thêm historical_candles nếu có
        if(needsHistorical && StringLen(historicalJSON) > 2)
        {
            symbolData += ",\"historical_candles\":" + historicalJSON;
        }
        
        symbolData += "}";

        if(SendOnlyOpenMarkets && !isOpen) continue;

        if(!first) symbolsData += ",";
        symbolsData += symbolData;
        first = false;
    }

    symbolsData += "]";
    jsonData += StringFormat("\"timestamp\":%lld,", TimeCurrent());
    jsonData += StringFormat("\"broker\":\"%s\",", brokerServer);
    jsonData += "\"data\":" + symbolsData;
    jsonData += "}";

    return jsonData;
}

//============================================================
// Hàm kiểm tra phiên giao dịch
bool FunCheckMartKetOpenMotCapTien(string symbol)
{
    MqlDateTime Curent_time;
    TimeCurrent(Curent_time);
    int day_of_week=Curent_time.day_of_week;
    int curent_time_second=Curent_time.hour*3600+Curent_time.min*60+Curent_time.sec;
    int start_time_second,finish_time_second;
    
    Section_Trade_Ngay_Trong_Tuan Section_Trade_Array_Mot_Cap_Tien[10];
    FunGetSectionTradeArrayMotCapTien(symbol,Section_Trade_Array_Mot_Cap_Tien);
    int tong_section_trade_hom_nay=Section_Trade_Array_Mot_Cap_Tien[day_of_week].str_Tong_Section_Trade_Moi_Ngay;
    for(int i = 0; i < tong_section_trade_hom_nay; i++)
    {
        MqlDateTime temp_time;
        long distant_Current_second=0;
        long distant_finish_second=0;
        start_time_second=0;finish_time_second=0;
        
        TimeToStruct(Section_Trade_Array_Mot_Cap_Tien[day_of_week].str_arr_Section_Trade_Moi_Ngay[i].str_start_time,temp_time);
        start_time_second=temp_time.hour*3600+temp_time.min*60+temp_time.sec;
        TimeToStruct(Section_Trade_Array_Mot_Cap_Tien[day_of_week].str_arr_Section_Trade_Moi_Ngay[i].str_finish_time,temp_time);
        finish_time_second=temp_time.hour*3600+temp_time.min*60+temp_time.sec;
        
        if(start_time_second==finish_time_second)
        {
            return true;//Thi truong chay 24/24
        }
        else if(start_time_second<finish_time_second)
        {
            if(start_time_second<=curent_time_second && curent_time_second<finish_time_second)
            return true;
        }
        else
        {
            if(start_time_second<=curent_time_second || curent_time_second<finish_time_second)
            return true;
        }
    }
    return false;
}

//============================================================
// Hàm lấy phiên giao dịch
void FunGetSectionTradeArrayMotCapTien(string _symbol, Section_Trade_Ngay_Trong_Tuan &_Section_Trade_Array[])
{
    MqlDateTime current_time;
    TimeCurrent(current_time);
    for(int day_of_week = 0; day_of_week < 7; day_of_week++)
    {
        _Section_Trade_Array[day_of_week].str_Tong_Section_Trade_Moi_Ngay=0;
        for(int i = 0; i < 5; i++)
        {
            Section_Trade Tam;
            Tam.str_finish_time=0;
            Tam.str_start_time=0;
            SymbolInfoSessionTrade(_symbol,(ENUM_DAY_OF_WEEK) day_of_week,i,Tam.str_start_time, Tam.str_finish_time);
            if(Tam.str_finish_time!=Tam.str_start_time)
            {
                _Section_Trade_Array[day_of_week].str_arr_Section_Trade_Moi_Ngay[_Section_Trade_Array[day_of_week].str_Tong_Section_Trade_Moi_Ngay]=Tam;
                _Section_Trade_Array[day_of_week].str_Tong_Section_Trade_Moi_Ngay++;
            }
        }
    }
}

//============================================================
// Hàm tạo JSON cho trade sessions
string GetTradeSessionsJSON(string symbol)
{
    Section_Trade_Ngay_Trong_Tuan Section_Trade_Array[10];
    FunGetSectionTradeArrayMotCapTien(symbol, Section_Trade_Array);
    
    MqlDateTime current_time;
    TimeCurrent(current_time);
    int today = current_time.day_of_week;
    
    string days[] = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
    
    string json = "{";
    json += "\"current_day\":\"" + days[today] + "\",";
    json += "\"days\":[";
    
    bool first_day = true;
    for(int day = 0; day < 7; day++)
    {
        int total_sessions = Section_Trade_Array[day].str_Tong_Section_Trade_Moi_Ngay;
        
        if(total_sessions > 0)
        {
            if(!first_day) json += ",";
            first_day = false;
            
            json += "{\"day\":\"" + days[day] + "\",\"sessions\":[";
            
            for(int i = 0; i < total_sessions; i++)
            {
                MqlDateTime start_time, end_time;
                TimeToStruct(Section_Trade_Array[day].str_arr_Section_Trade_Moi_Ngay[i].str_start_time, start_time);
                TimeToStruct(Section_Trade_Array[day].str_arr_Section_Trade_Moi_Ngay[i].str_finish_time, end_time);
                
                if(i > 0) json += ",";
                json += StringFormat("{\"start\":\"%02d:%02d\",\"end\":\"%02d:%02d\"}",
                    start_time.hour, start_time.min,
                    end_time.hour, end_time.min);
            }
            
            json += "]}";
        }
    }
    
    json += "]";
    json += "}";
    
    return json;
}

//============================================================
// Hàm lấy dữ liệu positions (orders)
string GetPositionsData()
{
    if(!ReadWebServerURL()) return "";
    
    string jsonData = "{";
    jsonData += StringFormat("\"timestamp\":%lld,", TimeCurrent());
    jsonData += StringFormat("\"broker\":\"%s\",", AccountServer());
    jsonData += "\"positions\":[";
    
    int total = OrdersTotal();
    bool first = true;
    
    for(int i = 0; i < total; i++)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        
        int ticket = OrderTicket();
        string symbol = OrderSymbol();
        int type = OrderType();
        double volume = OrderLots();
        double open_price = OrderOpenPrice();
        double sl = OrderStopLoss();
        double tp = OrderTakeProfit();
        double profit = OrderProfit();
        string comment = OrderComment();
        datetime open_time = OrderOpenTime();
        
        // Chỉ lấy positions (market orders), không lấy pending orders
        if(type != OP_BUY && type != OP_SELL) continue;
        
        double current_price = (type == OP_BUY) ? 
            MarketInfo(symbol, MODE_BID) : 
            MarketInfo(symbol, MODE_ASK);
        
        string posData = StringFormat(
            "{\"ticket\":%d,\"symbol\":\"%s\",\"type\":\"%s\",\"volume\":%.2f," +
            "\"open_price\":%.5f,\"current_price\":%.5f,\"sl\":%.5f,\"tp\":%.5f," +
            "\"profit\":%.2f,\"comment\":\"%s\",\"open_time\":%lld}",
            ticket, symbol, 
            (type == OP_BUY ? "BUY" : "SELL"),
            volume, open_price, current_price, sl, tp, profit,
            comment, (long)open_time
        );
        
        if(!first) jsonData += ",";
        jsonData += posData;
        first = false;
    }
    
    jsonData += "]}";
    return jsonData;
}

//============================================================
// Các hàm xử lý trade signals
bool HandleTrade(TradeSignal &sig)
{
    string resp = StringFormat("{\"action\":\"TRADE\",\"ticket\":%d,\"success\":false}", sig.ticket);
    
    if(sig.volume <= 0)
    {
        Print("Invalid volume: ", sig.volume);
        SendDataToWeb("POST", WebServerURL + "api/send_trade_response", resp);
        return false;
    }
    
    int order_type;
    if(sig.side == "BUY") order_type = OP_BUY;
    else if(sig.side == "SELL") order_type = OP_SELL;
    else if(sig.side == "BUY_LIMIT") order_type = OP_BUYLIMIT;
    else if(sig.side == "SELL_LIMIT") order_type = OP_SELLLIMIT;
    else if(sig.side == "BUY_STOP") order_type = OP_BUYSTOP;
    else if(sig.side == "SELL_STOP") order_type = OP_SELLSTOP;
    else {
        Print("Invalid order type: ", sig.side);
        SendDataToWeb("POST", WebServerURL + "api/send_trade_response", resp);
        return false;
    }
    
    double price = 0;
    if(order_type == OP_BUY || order_type == OP_BUYLIMIT || order_type == OP_BUYSTOP)
        price = MarketInfo(sig.symbol, MODE_ASK);
    else
        price = MarketInfo(sig.symbol, MODE_BID);
    
    if(price <= 0)
    {
        Print("Invalid price for symbol: ", sig.symbol);
        SendDataToWeb("POST", WebServerURL + "api/send_trade_response", resp);
        return false;
    }
    
    double point = MarketInfo(sig.symbol, MODE_POINT);
    double sl = 0, tp = 0;
    
    if(sig.sl_points > 0)
    {
        if(order_type == OP_BUY || order_type == OP_BUYLIMIT || order_type == OP_BUYSTOP)
            sl = price - sig.sl_points * point;
        else
            sl = price + sig.sl_points * point;
    }
    
    if(sig.tp_points > 0)
    {
        if(order_type == OP_BUY || order_type == OP_BUYLIMIT || order_type == OP_BUYSTOP)
            tp = price + sig.tp_points * point;
        else
            tp = price - sig.tp_points * point;
    }
    
    int ticket = OrderSend(sig.symbol, order_type, sig.volume, price, sig.max_slippage, sl, tp, sig.comment, 0, 0);
    
    bool ok = (ticket > 0);
    
    if(ok)
    {
        resp = StringFormat("{\"action\":\"TRADE\",\"ticket\":%d,\"success\":true,\"new_ticket\":%d}", 
                           sig.ticket, ticket);
        Print("Trade opened successfully: #", ticket);
    }
    else
    {
        Print("Trade failed: Ticket #", sig.ticket, " Error: ", GetLastError());
    }
    
    SendDataToWeb("POST", WebServerURL + "api/send_trade_response", resp);
    return ok;
}

bool HandleClose(TradeSignal &sig)
{
    string resp = StringFormat("{\"action\":\"CLOSE\",\"ticket\":%d,\"success\":false}", sig.ticket);
    
    bool ok = false;
    if(OrderSelect(sig.ticket, SELECT_BY_TICKET))
    {
        double price = (OrderType() == OP_BUY) ? 
            MarketInfo(OrderSymbol(), MODE_BID) : 
            MarketInfo(OrderSymbol(), MODE_ASK);
            
        ok = OrderClose(sig.ticket, OrderLots(), price, sig.max_slippage);
        
        if(ok)
        {
            resp = StringFormat("{\"action\":\"CLOSE\",\"ticket\":%d,\"success\":true}", sig.ticket);
            Print("Position closed: #", sig.ticket);
        }
        else
            Print("Close failed: Ticket #", sig.ticket, " Error: ", GetLastError());
    }
    else
    {
        Print("Position not found: #", sig.ticket);
    }
    
    SendDataToWeb("POST", WebServerURL + "api/send_close_response", resp);
    return ok;
}

bool HandleCancelPending(TradeSignal &sig)
{
    string resp = StringFormat("{\"action\":\"CANCEL_PENDING\",\"ticket\":%d,\"success\":false}", sig.ticket);
    
    bool ok = false;
    if(OrderSelect(sig.ticket, SELECT_BY_TICKET))
    {
        ok = OrderDelete(sig.ticket);
        
        if(ok)
        {
            resp = StringFormat("{\"action\":\"CANCEL_PENDING\",\"ticket\":%d,\"success\":true}", sig.ticket);
            Print("Pending order cancelled: #", sig.ticket);
        }
        else
            Print("Cancel failed: Ticket #", sig.ticket, " Error: ", GetLastError());
    }
    else
    {
        Print("Order not found: #", sig.ticket);
    }
    
    SendDataToWeb("POST", WebServerURL + "api/send_cancel_pending_response", resp);
    return ok;
}

// Hàm lấy value của 1 key trong JSON đơn giản
string GetJsonString(string json, string key)
{
    string pattern = "\"" + key + "\"";
    int pos = StringFind(json, pattern);
    if(pos < 0) return "";
    int colon = StringFind(json, ":", pos);
    if(colon < 0) return "";
    int start = colon+1;

    // Bỏ qua khoảng trắng
    while(start < StringLen(json) && (StringGetChar(json,start)==' ')) start++;

    // Nếu có dấu " thì bỏ
    if(start < StringLen(json) && StringGetChar(json,start)=='\"') start++;

    // Tìm dấu kết thúc
    int end = StringFind(json, "\"", start);
    if(end < 0) {
        end = StringFind(json, ",", start);
        if(end < 0) end = StringFind(json, "}", start);
    }
    if(end < 0) return "";

    return StringSubstr(json,start,end-start);
}

// Parse JSON thành TradeSignal
bool ParseTradeSignal(string json, TradeSignal &sig)
{
    sig.action         = GetJsonString(json, "action");
    sig.symbol         = GetJsonString(json, "symbol");
    sig.side           = GetJsonString(json, "side");
    sig.comment        = GetJsonString(json, "comment");
    sig.volume         = StringToDouble(GetJsonString(json, "volume"));
    sig.sl_points      = StringToDouble(GetJsonString(json, "sl_points"));
    sig.tp_points      = StringToDouble(GetJsonString(json, "tp_points"));
    sig.max_slippage   = (int)StringToDouble(GetJsonString(json, "max_slippage"));
    sig.ticket         = (int)StringToDouble(GetJsonString(json, "ticket"));

    return (sig.action != "");
}

void CheckSignalFromServer()
{
    string result_headers;
    char post[], result[];
    int timeout = 5000;

    string url = WebServerURL + "api/get_signal?broker=" + AccountServer();
    int res = WebRequest("GET", url, "", timeout, post, result, result_headers);

    if(res == -1) {
        Print("ERR: Khong lay duoc tin hieu. ", GetLastError());
        return;
    }

    string response = CharArrayToString(result,0,-1);
    if(StringLen(response) < 2) return;

    global_last_response = response;

    TradeSignal sig;
    if(ParseTradeSignal(response, sig)) {
        if(sig.action == "TRADE") HandleTrade(sig);
        else if(sig.action == "CLOSE") HandleClose(sig);
        else if(sig.action == "CANCEL_PENDING") HandleCancelPending(sig);
    }
}

//============================================================
void OnTimer()
{
    // Gửi dữ liệu giá
    string jsonData = GetMarketWatchData();
    if(StringLen(jsonData) > 2)
    {
        SendDataToWeb("POST", WebServerURL + "api/receive_data", jsonData);
    }       

    // Gửi dữ liệu position
    string positionsData = GetPositionsData();
    if(StringLen(positionsData) > 2)
    {
        SendDataToWeb("POST", WebServerURL + "api/receive_positions", positionsData);               
    }
          
    CheckSignalFromServer();               
}

void FunWriteDataToFile()
{
    int file_handle=FileOpen(glbStringFilePath+".txt",FILE_WRITE|FILE_TXT);
    if(file_handle!=INVALID_HANDLE)
    {
          FileWrite(file_handle,"http://127.0.0.1:80");                   
    }
    FileClose(file_handle);
}

int OnInit()
{
    if(!ReadWebServerURL())
    {
        FunWriteDataToFile();
    }

    // Reset historical data tracking khi EA khởi động
    // Điều này đảm bảo EA sẽ gửi dữ liệu lịch sử cho tất cả symbols
    // khi được attach vào chart (bất kể trường hợp mở hay đóng)
    ResetHistoricalDataTracking();

    EventSetTimer(SendInterval);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    EventKillTimer();               
}
