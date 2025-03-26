import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:xml/xml.dart' as xml;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:pointycastle/digests/sha256.dart';

class TradingLogic {
  Map<String, List<double>> prices = {'BTC-USD': [], 'ETH-USD': [], 'SOL-USD': []};
  Map<String, List<double>> volumes = {'BTC-USD': [], 'ETH-USD': [], 'SOL-USD': []};
  Map<String, List<double>> prices4h = {'BTC-USD': [], 'ETH-USD': [], 'SOL-USD': []};
  Map<String, List<double>> prices15m = {'BTC-USD': [], 'ETH-USD': [], 'SOL-USD': []};
  Map<String, List<double>> prices1d = {'BTC-USD': [], 'ETH-USD': [], 'SOL-USD': []};
  Map<String, double> lastPrices = {};
  Map<String, bool> inPosition = {};
  Map<String, bool> inDayPosition = {};
  Map<String, bool> inShortPosition = {};
  Map<String, double> entryPrices = {};
  Map<String, double> dayEntryPrices = {};
  Map<String, double> shortEntryPrices = {};
  Map<String, double> highestPrices = {};
  Map<String, double> dayHighestPrices = {};
  Map<String, double> lowestPrices = {};
  Map<String, double> atrs = {};
  Map<String, double> positionSizes = {};
  Map<String, double> dayPositionSizes = {};
  Map<String, double> shortPositionSizes = {};
  Map<String, int> tradesWon = {};
  Map<String, int> tradesLost = {};
  Map<String, double> totalGain = {};
  Map<String, double> totalLoss = {};
  double capital = 1000.0;
  double dailyPnl = 0.0;
  double initialCapital = 1000.0;
  List<String> emergingCoins = [];
  Map<String, double> sentimentScores = {};
  List<double> capitalHistory = [1000.0];
  List<String> logs = [];
  Map<String, int> apiQueue = {};
  Map<String, Map<String, dynamic>> pendingTrades = {};
  int dailyDayTrades = 0;
  DateTime lastDayTradeReset = DateTime.now();

  final String apiKey = '0bd47ccf-672e-4a47-8a39-c0b599b9f388';
  final String privateKeyPem = '''-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIBo4u9ArJj/g0HJ/6sAzBQ326yOIuakclgPdal7CtTrToAoGCCqGSM49
AwEHoUQDQgAElaRopzUL4+6mYlMoVoUe72o8eQMJDzjm5wmPOGVHT8jcL4GW4+yS
pGTtGz2tiiFAmHsviMRb3Ws6QIpJad/T5w==
-----END EC PRIVATE KEY-----''';
  final String googleNlpApiKey = 'AIzaSyAVkocaWzdxlBUjE2O7TDWE_qQF6ZdiiZo';
  final String newsApiKey = '81ad4b58401542c7a7cf255ba632a858';

  Map<String, Map<String, double>> qTable = {
    '2-1-8': {'highRisk': 25.0, 'highProfit': 30.0, 'lowRisk': 10.0, 'medRisk': 15.0, 'lowProfit': 12.0, 'shortLowRisk': 5.0, 'shortHighRisk': 8.0},
    '1--5--7': {'shortHighRisk': 20.0, 'highProfit': 22.0, 'shortLowRisk': 15.0, 'lowRisk': 8.0, 'medRisk': 10.0, 'lowProfit': 12.0, 'highRisk': 5.0},
    '3-2--8': {'shortLowRisk': 15.0, 'lowProfit': 12.0, 'shortHighRisk': 10.0, 'lowRisk': 5.0, 'medRisk': 8.0, 'highRisk': 3.0, 'highProfit': 6.0},
  };
  double learningRate = 0.1;
  double discountFactor = 0.9;
  double explorationRate = 0.1;
  Random random = Random();

  double newsSentiment = 0.0;

  Map<String, double> mlModel = {
    'bias': -2.0,
    'price_change': 0.5,
    'rsi': 0.03,
    'sma_diff': 0.8,
    'volume_change': 0.2,
    'news_sentiment': 0.5,
  };
}  String signRequest(String timestamp, String method, String path, String body) {
    final privateKeyBytes = base64Decode(privateKeyPem.split('\n')[1].trim());
    final privateKey = ECPrivateKey(BigInt.parse(base64.encode(privateKeyBytes), radix: 64), ECCurve_secp256r1());
    final signer = ECDSASigner(SHA256Digest());
    signer.init(true, PrivateKeyParameter(privateKey));
    final message = '$timestamp$method$path$body';
    final signature = signer.generateSignature(utf8.encode(message)) as ECSignature;
    return base64.encode(signature.r.toRadixString(16).codeUnits + signature.s.toRadixString(16).codeUnits);
  }

  Future<void> loadState() async {
    final prefs = await SharedPreferences.getInstance();
    capital = prefs.getDouble('capital') ?? 1000.0;
    dailyPnl = prefs.getDouble('dailyPnl') ?? 0.0;
    capitalHistory = (prefs.getStringList('capitalHistory') ?? ['1000.0']).map(double.parse).toList();
    String? pendingJson = prefs.getString('pendingTrades');
    if (pendingJson != null) pendingTrades = jsonDecode(pendingJson).map((k, v) => MapEntry(k, Map<String, dynamic>.from(v)));
  }

  Future<void> saveState() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setDouble('capital', capital);
    prefs.setDouble('dailyPnl', dailyPnl);
    prefs.setStringList('capitalHistory', capitalHistory.map((e) => e.toString()).toList());
    prefs.setString('pendingTrades', jsonEncode(pendingTrades));
  }

  Future<void> syncWithAccount() async {
    final timestamp = (DateTime.now().millisecondsSinceEpoch / 1000).toString();
    final method = 'GET';
    final path = '/api/v3/brokerage/accounts';
    final body = '';
    final signature = signRequest(timestamp, method, path, body);

    final response = await queueApiCall(() => http.get(
      Uri.parse('https://api.coinbase.com$path'),
      headers: {
        'CB-ACCESS-KEY': apiKey,
        'CB-ACCESS-SIGN': signature,
        'CB-ACCESS-TIMESTAMP': timestamp,
      },
    ));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      double usdBalance = double.parse(data['accounts'].firstWhere((acc) => acc['currency'] == 'USD', orElse: () => {'available_balance': {'value': '0'}})['available_balance']['value']);
      capital = usdBalance + inPosition.entries.fold(0.0, (sum, e) => sum + (e.value ? positionSizes[e.key]! * lastPrices[e.key]! : 0)) +
          inDayPosition.entries.fold(0.0, (sum, e) => sum + (e.value ? dayPositionSizes[e.key]! * lastPrices[e.key]! : 0));
      logs.add('Synced with account: Capital adjusted to \$${capital.toStringAsFixed(2)}');
    } else {
      logs.add('Account sync failed: ${response.body}');
      notify('Sync Error', 'Failed to sync with Coinbase account');
    }
  }

  Future<bool> healthCheck() async {
    final timestamp = (DateTime.now().millisecondsSinceEpoch / 1000).toString();
    final method = 'GET';
    final path = '/api/v3/brokerage/time';
    final body = '';
    final signature = signRequest(timestamp, method, path, body);

    bool apiAlive = (await http.get(
      Uri.parse('https://api.coinbase.com$path'),
      headers: {
        'CB-ACCESS-KEY': apiKey,
        'CB-ACCESS-SIGN': signature,
        'CB-ACCESS-TIMESTAMP': timestamp,
      },
    )).statusCode == 200;

    if (!apiAlive) {
      logs.add('Health check failed: API: $apiAlive');
      notify('Health Check Failed', 'API connection issue detected');
    }
    return apiAlive;
  }

  Future<void> fetchGovernmentFinancialNews() async {
    final response = await http.get(Uri.parse('https://newsapi.org/v2/everything?q=finance+government+bitcoin&apiKey=$newsApiKey'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body)['articles'];
      double totalSentiment = 0.0;
      int count = 0;
      for (var article in data.take(10)) {
        var sentimentResponse = await http.post(
          Uri.parse('https://language.googleapis.com/v1/documents:analyzeSentiment?key=$googleNlpApiKey'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'document': {'type': 'PLAIN_TEXT', 'content': article['title']},
            'encodingType': 'UTF8',
          }),
        );
        if (sentimentResponse.statusCode == 200) {
          var sentimentData = jsonDecode(sentimentResponse.body);
          double score = sentimentData['documentSentiment']['score'];
          totalSentiment += score * 10;
          count++;
        }
      }
      newsSentiment = count > 0 ? totalSentiment / count : 0.0;
      logs.add('News Sentiment Updated: $newsSentiment');
    }
  }

  Future<void> fetchXCoins() async {
    List<Map<String, dynamic>> xPosts = [
      {'coin': 'NOVA-USD', 'posts': 100, 'uniqueUsers': 60, 'sentiment': 0.7, 'topUserFollowers': 15000, 'topUserAgeMonths': 24, 'retweets': 400, 'timeSpanHours': 24, 'link': 'nova.xyz', 'scamMentions': 0.05},
      {'coin': 'X1-USD', 'posts': 80, 'uniqueUsers': 50, 'sentiment': 0.65, 'topUserFollowers': 12000, 'topUserAgeMonths': 18, 'retweets': 350, 'timeSpanHours': 20, 'link': 'x1.xyz', 'scamMentions': 0.1},
      {'coin': 'X2-USD', 'posts': 90, 'uniqueUsers': 55, 'sentiment': 0.68, 'topUserFollowers': 13000, 'topUserAgeMonths': 20, 'retweets': 380, 'timeSpanHours': 22, 'link': 'x2.xyz', 'scamMentions': 0.08},
      {'coin': 'X3-USD', 'posts': 70, 'uniqueUsers': 45, 'sentiment': 0.72, 'topUserFollowers': 11000, 'topUserAgeMonths': 16, 'retweets': 320, 'timeSpanHours': 18, 'link': 'x3.xyz', 'scamMentions': 0.07},
      {'coin': 'X4-USD', 'posts': 85, 'uniqueUsers': 52, 'sentiment': 0.70, 'topUserFollowers': 14000, 'topUserAgeMonths': 22, 'retweets': 360, 'timeSpanHours': 21, 'link': 'x4.xyz', 'scamMentions': 0.06},
    ];

    for (var post in xPosts) {
      String symbol = post['coin'];
      double trustScore = 0.0;

      if (post['topUserFollowers'] > 10000 && post['topUserAgeMonths'] > 12) trustScore += 0.3;
      else if (post['topUserFollowers'] < 1000 && post['topUserAgeMonths'] < 3) trustScore -= 0.2;
      if (post['uniqueUsers'] > 50 && post['sentiment'] >= 0.6 && post['sentiment'] <= 0.8) trustScore += 0.2;
      if (post['sentiment'] > 0.9 && post['uniqueUsers'] < 20) trustScore -= 0.3;
      if (post['link'].endsWith('.xyz')) trustScore += 0.3;
      if (post['retweets'] > 500 && post['timeSpanHours'] < 1) trustScore -= 0.5;
      if (post['retweets'] > 100 && post['timeSpanHours'] > 12) trustScore += 0.1;

      bool hasLiquidity = await checkLiquidity(symbol.split('-')[0] + '-USD');
      if (hasLiquidity) trustScore += 0.1;
      if (post['scamMentions'] > 0.2) trustScore -= 0.3;

      if (trustScore > 0.6) {
        if (!emergingCoins.contains(symbol)) {
          emergingCoins.add(symbol);
          prices[symbol] ??= [];
          volumes[symbol] ??= [];
          prices4h[symbol] ??= [];
          prices15m[symbol] ??= [];
          prices1d[symbol] ??= [];
          sentimentScores[symbol] = post['sentiment'];
          logs.add('X: $symbol identified as upcoming (Trust: ${trustScore.toStringAsFixed(2)})');
          await fetchSentiment(symbol);
        }
      } else {
        logs.add('X: $symbol filtered as hype trap (Trust: ${trustScore.toStringAsFixed(2)})');
      }
    }
  }  Future<void> detectEmergingCoins() async {
    await fetchXCoins();
    final timestamp = (DateTime.now().millisecondsSinceEpoch / 1000).toString();
    final method = 'GET';
    final path = '/api/v3/brokerage/products';
    final body = '';
    final signature = signRequest(timestamp, method, path, body);

    final response = await http.get(
      Uri.parse('https://api.coinbase.com$path'),
      headers: {
        'CB-ACCESS-KEY': apiKey,
        'CB-ACCESS-SIGN': signature,
        'CB-ACCESS-TIMESTAMP': timestamp,
      },
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body)['products'] as List;
      for (var asset in data) {
        String symbol = asset['product_id'];
        if (!symbol.endsWith('-USD')) continue;
        double priceChange = double.parse(asset['price_percentage_change_24h'] ?? '0');
        double volume = double.parse(asset['volume_24h'] ?? '0');
        double avgVolume = volumes[symbol]?.isNotEmpty ?? false ? volumes[symbol]!.reduce((a, b) => a + b) / volumes[symbol]!.length : volume;
        if (priceChange > 20 && volume > avgVolume * 5 && !emergingCoins.contains(symbol) && !prices.containsKey(symbol)) {
          emergingCoins.add(symbol);
          prices[symbol] ??= [];
          volumes[symbol] ??= [];
          prices4h[symbol] ??= [];
          prices15m[symbol] ??= [];
          prices1d[symbol] ??= [];
          await fetchSentiment(symbol);
        }
      }
    }
    await fetchNews();
    await fetchGovernmentFinancialNews();
  }

  Future<void> fetchSentiment(String symbol) async {
    final coin = symbol.split('-')[0];
    final response = await http.post(
      Uri.parse('https://language.googleapis.com/v1/documents:analyzeSentiment?key=$googleNlpApiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'document': {'type': 'PLAIN_TEXT', 'content': '$coin crypto'},
        'encodingType': 'UTF8',
      }),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      double score = data['documentSentiment']['score'];
      sentimentScores[symbol] = score > 0.1 ? 0.75 : score < -0.1 ? 0.25 : 0.5;
    }
  }

  Future<void> fetchNews() async {
    final response = await http.get(Uri.parse('https://blog.coinbase.com/feed'));
    if (response.statusCode == 200) {
      final document = xml.XmlDocument.parse(response.body);
      for (var item in document.findAllElements('item')) {
        final title = item.findElements('title').single.text;
        if (title.contains('Now Available') || title.contains('Listing')) {
          final coinMatch = RegExp(r'[A-Z]{2,5}').firstMatch(title);
          if (coinMatch != null) {
            String symbol = '${coinMatch.group(0)}-USD';
            if (!emergingCoins.contains(symbol)) {
              emergingCoins.add(symbol);
              prices[symbol] ??= [];
              volumes[symbol] ??= [];
              prices4h[symbol] ??= [];
              prices15m[symbol] ??= [];
              prices1d[symbol] ??= [];
              logs.add('News: Potential new listing - $symbol');
            }
          }
        }
      }
    }
  }

  void updatePrice(String symbol, double price, double volume, bool is4h, bool is15m) {
    prices[symbol] ??= [];
    volumes[symbol] ??= [];
    prices4h[symbol] ??= [];
    prices15m[symbol] ??= [];
    prices1d[symbol] ??= [];
    if (!is4h && !is15m) {
      prices[symbol]!.add(price);
      volumes[symbol]!.add(volume);
      lastPrices[symbol] = price;
      if (DateTime.now().hour == 0 && DateTime.now().minute == 0) prices1d[symbol]!.add(price);
    } else if (is4h) {
      prices4h[symbol]!.add(price);
    } else if (is15m) {
      prices15m[symbol]!.add(price);
    }

    if (prices[symbol]!.length > 20) {
      prices[symbol]!.removeAt(0);
      volumes[symbol]!.removeAt(0);
      double range = prices[symbol]!.reduce(max) - prices[symbol]!.reduce(min);
      atrs[symbol] = range / 14;
      checkTrade(symbol);
    }
    if (prices4h[symbol]!.length > 20) prices4h[symbol]!.removeAt(0);
    if (prices15m[symbol]!.length > 20) {
      prices15m[symbol]!.removeAt(0);
      dayTrade(symbol);
    }
    if (prices1d[symbol]!.length > 7) prices1d[symbol]!.removeAt(0);
  }

  Map<String, dynamic> calculateIndicators(String symbol, {bool isDayTrade = false}) {
    List<double> priceList = isDayTrade ? prices15m[symbol]! : prices[symbol]!;
    double shortSMA = priceList.take(5).reduce((a, b) => a + b) / 5;
    double longSMA = priceList.reduce((a, b) => a + b) / 20;
    double sma4h = prices4h[symbol]!.isNotEmpty ? prices4h[symbol]!.reduce((a, b) => a + b) / prices4h[symbol]!.length : longSMA;
    double sma1d = prices1d[symbol]!.isNotEmpty ? prices1d[symbol]!.reduce((a, b) => a + b) / prices1d[symbol]!.length : longSMA;
    double avgGain = priceList.take(14).where((p) => p > priceList[priceList.length - 1]).fold(0.0, (a, b) => a + b) / 14;
    double avgLoss = priceList.take(14).where((p) => p < priceList[priceList.length - 1]).fold(0.0, (a, b) => a + b).abs() / 14;
    double rsi = avgLoss == 0 ? 100 : 100 - (100 / (1 + avgGain / avgLoss));
    double mean = priceList.reduce((a, b) => a + b) / priceList.length;
    double stdDev = sqrt(priceList.map((p) => pow(p - mean, 2)).reduce((a, b) => a + b) / priceList.length);
    double upperBB = mean + 2 * stdDev;
    double lowerBB = mean - 2 * stdDev;
    return {'shortSMA': shortSMA, 'longSMA': longSMA, 'sma4h': sma4h, 'sma1d': sma1d, 'rsi': rsi, 'upperBB': upperBB, 'lowerBB': lowerBB};
  }

  double predictBuyConfidence(String symbol, {bool isDayTrade = false}) {
    var indicators = calculateIndicators(symbol, isDayTrade: isDayTrade);
    List<double> priceList = isDayTrade ? prices15m[symbol]! : prices[symbol]!;
    double priceChange = priceList.length > 1 ? (lastPrices[symbol]! - priceList[priceList.length - 2]) / priceList[priceList.length - 2] : 0;
    double volumeChange = volumes[symbol]!.length > 1 ? (volumes[symbol]!.last - volumes[symbol]![volumes[symbol]!.length - 2]) / volumes[symbol]![volumes[symbol]!.length - 2] : 0;
    double smaDiff = indicators['shortSMA']! - indicators['longSMA']!;
    double rsi = indicators['rsi']!;
    double logit = mlModel['bias']! + mlModel['price_change']! * priceChange + mlModel['rsi']! * rsi +
                  mlModel['sma_diff']! * smaDiff + mlModel['volume_change']! * volumeChange + mlModel['news_sentiment']! * newsSentiment;
    return 1 / (1 + exp(-logit));
  }

  Future<bool> checkLiquidity(String symbol) async {
    final timestamp = (DateTime.now().millisecondsSinceEpoch / 1000).toString();
    final method = 'GET';
    final path = '/api/v3/brokerage/products/$symbol/book?level=2';
    final body = '';
    final signature = signRequest(timestamp, method, path, body);

    final response = await queueApiCall(() => http.get(
      Uri.parse('https://api.coinbase.com$path'),
      headers: {
        'CB-ACCESS-KEY': apiKey,
        'CB-ACCESS-SIGN': signature,
        'CB-ACCESS-TIMESTAMP': timestamp,
      },
    ));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      double bidVolume = (data['bids'] as List).take(5).fold(0.0, (sum, bid) => sum + double.parse(bid['size']));
      return bidVolume * lastPrices[symbol]! > 1000;
    }
    return false;
  }

  double calculateMarketVolatility() {
    double totalAtr = atrs.values.fold(0.0, (sum, atr) => sum + atr);
    double avgAtr = totalAtr / atrs.length.clamp(1, double.infinity);
    return avgAtr / lastPrices.values.reduce((a, b) => a + b) / lastPrices.length;
  }

  double calculateVolatility15m(String symbol) {
    return prices15m[symbol]!.isNotEmpty ? (prices15m[symbol]!.reduce(max) - prices15m[symbol]!.reduce(min)) / prices15m[symbol]!.last : 0;
  }

  String getState(String symbol, bool isDayTrade) {
    var indicators = calculateIndicators(symbol, isDayTrade: isDayTrade);
    double rsi = indicators['rsi']!;
    double smaDiff = indicators['shortSMA']! - indicators['longSMA']!;
    String rsiBucket = (rsi ~/ 20).toString();
    String smaBucket = (smaDiff ~/ (lastPrices[symbol]! * 0.01)).toString();
    String newsBucket = (newsSentiment * 10).round().toString();
    return '$rsiBucket-$smaBucket-$newsBucket';
  }

  Map<String, double> getActions(String state, bool isDayTrade) {
    qTable[state] ??= {
      'lowRisk': 0.0,
      'medRisk': 0.0,
      'highRisk': 0.0,
      'lowProfit': 0.0,
      'highProfit': 0.0,
      'shortLowRisk': 0.0,
      'shortHighRisk': 0.0,
    };
    return qTable[state]!;
  }

  String chooseAction(String state, bool isDayTrade) {
    var actions = getActions(state, isDayTrade);
    if (random.nextDouble() < explorationRate) {
      return actions.keys.elementAt(random.nextInt(actions.length));
    }
    return actions.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  void updateQTable(String state, String action, double reward, String nextState, bool isDayTrade) {
    var actions = getActions(state, isDayTrade);
    var nextActions = getActions(nextState, isDayTrade);
    double maxNextQ = nextActions.values.reduce(max);
    actions[action] = actions[action]! + learningRate * (reward + discountFactor * maxNextQ - actions[action]!);
  }

  double getDynamicRisk(String symbol, bool isDayTrade) {
    double base = isDayTrade ? 0.03 : (emergingCoins.contains(symbol) ? 0.02 : 0.05);
    double capitalFactor = (capital / initialCapital).clamp(1.0, 2.0);
    double atrFactor = 1 / (1 + atrs[symbol]! / lastPrices[symbol]!);
    return base * capitalFactor * atrFactor;
  }

  double getTrailingStop(String symbol, bool isShort) {
    if (isShort) {
      return prices1d[symbol]!.isNotEmpty ? prices1d[symbol]!.reduce(min) * 1.01 : lowestPrices[symbol]! * 1.01;
    }
    return prices1d[symbol]!.isNotEmpty ? prices1d[symbol]!.reduce(max) * 0.99 : highestPrices[symbol]! * 0.99;
  }  void checkTrade(String symbol) async {
    if (dailyPnl < -0.10 * capital || capital < 0.75 * initialCapital || !await healthCheck()) return;
    if (prices[symbol]!.length > 2 && prices[symbol]!.last / prices[symbol]![prices[symbol]!.length - 2] < 0.8) {
      logs.add('$symbol crashed >20% - pausing');
      return;
    }
    double volatility15m = calculateVolatility15m(symbol);
    if (volatility15m > 0.05) {
      logs.add('$symbol 15m volatility >5% - pausing');
      return;
    }

    var indicators = calculateIndicators(symbol);
    double shortSMA = indicators['shortSMA']!;
    double longSMA = indicators['longSMA']!;
    double sma4h = indicators['sma4h']!;
    double sma1d = indicators['sma1d']!;
    double rsi = indicators['rsi']!;
    double upperBB = indicators['upperBB']!;
    double lowerBB = indicators['lowerBB']!;
    double lastPrice = lastPrices[symbol]!;
    double atr = atrs[symbol] ?? 0.0;
    double marketVolatility = calculateMarketVolatility();
    String state = getState(symbol, false);
    String action = chooseAction(state, false);
    double baseRisk = action == 'lowRisk' ? 0.02 : action == 'medRisk' ? 0.05 : action == 'shortLowRisk' ? 0.02 : action == 'shortHighRisk' ? 0.05 : 0.05 * (1 + newsSentiment.clamp(0, 1));
    double riskPerTrade = getDynamicRisk(symbol, false) * (action == 'lowRisk' || action == 'shortLowRisk' ? 0.5 : action == 'medRisk' ? 1.0 : 1 + newsSentiment.clamp(0, 1));
    double sentiment = sentimentScores[symbol] ?? 0.0;
    double takeProfit = action == 'lowProfit' ? 0.20 : 0.30 + (2 * atr / lastPrice) * (1 + newsSentiment.clamp(0, 1));
    double buyConfidence = predictBuyConfidence(symbol);
    double btcAllocation = capital * 0.5;
    double topEmergingAllocation = capital * 0.3 / emergingCoins.length;
    double otherAllocation = capital * 0.2 / (prices.keys.length - emergingCoins.length - 1);

    inPosition[symbol] ??= false;
    inShortPosition[symbol] ??= false;
    highestPrices[symbol] ??= lastPrice;
    lowestPrices[symbol] ??= lastPrice;

    if (!await checkLiquidity(symbol)) return;

    if (shortSMA > longSMA && sma4h < lastPrice && sma1d < lastPrice && rsi > 60 && lastPrice < upperBB && !inPosition[symbol]! && !inShortPosition[symbol]! && sentiment > 0.5 && buyConfidence > 0.65) {
      double alloc = symbol == 'BTC-USD' ? btcAllocation : (emergingCoins.contains(symbol) ? topEmergingAllocation : otherAllocation);
      double quantity = (alloc * riskPerTrade) / lastPrice;
      if (quantity * lastPrice < 1.0) return;
      pendingTrades[symbol] = {'side': 'BUY', 'quantity': quantity, 'price': lastPrice};
      placeOrder('BUY', symbol, quantity);
      inPosition[symbol] = true;
      entryPrices[symbol] = lastPrice;
      highestPrices[symbol] = lastPrice;
      positionSizes[symbol] = quantity;
      logs.add('SWING BUY $quantity $symbol @ $lastPrice (Confidence: ${buyConfidence.toStringAsFixed(2)})');
      pendingTrades.remove(symbol);
    } else if (shortSMA < longSMA && sma4h > lastPrice && sma1d > lastPrice && rsi < 40 && lastPrice > lowerBB && !inPosition[symbol]! && !inShortPosition[symbol]! && sentiment < 0.5 && buyConfidence < 0.35) {
      double alloc = symbol == 'BTC-USD' ? btcAllocation : (emergingCoins.contains(symbol) ? topEmergingAllocation : otherAllocation);
      double quantity = (alloc * riskPerTrade) / lastPrice;
      if (quantity * lastPrice < 1.0) return;
      pendingTrades[symbol] = {'side': 'SELL', 'quantity': quantity, 'price': lastPrice, 'isShort': true};
      placeOrder('SELL', symbol, quantity);
      inShortPosition[symbol] = true;
      shortEntryPrices[symbol] = lastPrice;
      lowestPrices[symbol] = lastPrice;
      shortPositionSizes[symbol] = quantity;
      logs.add('SWING SHORT SELL $quantity $symbol @ $lastPrice (Confidence: ${buyConfidence.toStringAsFixed(2)})');
      pendingTrades.remove(symbol);
    } else if (inPosition[symbol]!) {
      double profitPercent = (lastPrice - entryPrices[symbol]!) / entryPrices[symbol]!;
      if (profitPercent >= takeProfit || lastPrice > upperBB) {
        double quantity = positionSizes[symbol]! / 2;
        pendingTrades[symbol] = {'side': 'SELL', 'quantity': quantity, 'price': lastPrice};
        placeOrder('SELL', symbol, quantity);
        positionSizes[symbol] = positionSizes[symbol]! - quantity;
        double profit = quantity * lastPrice * (1 - 0.004);
        capital += profit;
        dailyPnl += profit * profitPercent;
        tradesWon[symbol] = (tradesWon[symbol] ?? 0) + 1;
        totalGain[symbol] = (totalGain[symbol] ?? 0) + profit;
        capitalHistory.add(capital);
        logs.add('SWING SELL $quantity $symbol @ $lastPrice (Take-Profit)');
        String nextState = getState(symbol, false);
        updateQTable(state, action, profit, nextState, false);
        saveState();
        pendingTrades.remove(symbol);
      }
      highestPrices[symbol] = max(highestPrices[symbol]!, lastPrice);
      double stopPercent = getTrailingStop(symbol, false) / lastPrice;
      if (lastPrice < stopPercent || rsi < 40 || lastPrice < lowerBB) {
        double quantity = positionSizes[symbol]!;
        pendingTrades[symbol] = {'side': 'SELL', 'quantity': quantity, 'price': lastPrice};
        placeOrder('SELL', symbol, quantity);
        inPosition[symbol] = false;
        double tradePnl = quantity * (lastPrice - entryPrices[symbol]!) * (1 - 0.004);
        capital += quantity * lastPrice * (1 - 0.004);
        dailyPnl += tradePnl;
        if (tradePnl > 0) {
          tradesWon[symbol] = (tradesWon[symbol] ?? 0) + 1;
          totalGain[symbol] = (totalGain[symbol] ?? 0) + tradePnl;
        } else {
          tradesLost[symbol] = (tradesLost[symbol] ?? 0) + 1;
          totalLoss[symbol] = (totalLoss[symbol] ?? 0) + tradePnl.abs();
        }
        capitalHistory.add(capital);
        logs.add('SWING SELL $quantity $symbol @ $lastPrice (Stop)');
        String nextState = getState(symbol, false);
        updateQTable(state, action, tradePnl, nextState, false);
        positionSizes.remove(symbol);
        saveState();
        pendingTrades.remove(symbol);
      }
    } else if (inShortPosition[symbol]!) {
      double profitPercent = (shortEntryPrices[symbol]! - lastPrice) / shortEntryPrices[symbol]!;
      if (profitPercent >= takeProfit || lastPrice < lowerBB) {
        double quantity = shortPositionSizes[symbol]!;
        pendingTrades[symbol] = {'side': 'BUY', 'quantity': quantity, 'price': lastPrice, 'isShort': true};
        placeOrder('BUY', symbol, quantity);
        inShortPosition[symbol] = false;
        double profit = quantity * (shortEntryPrices[symbol]! - lastPrice) * (1 - 0.004);
        capital += profit;
        dailyPnl += profit * profitPercent;
        tradesWon[symbol] = (tradesWon[symbol] ?? 0) + 1;
        totalGain[symbol] = (totalGain[symbol] ?? 0) + profit;
        capitalHistory.add(capital);
        logs.add('SWING SHORT BUY $quantity $symbol @ $lastPrice (Take-Profit)');
        String nextState = getState(symbol, false);
        updateQTable(state, action, profit, nextState, false);
        shortPositionSizes.remove(symbol);
        saveState();
        pendingTrades.remove(symbol);
      }
      lowestPrices[symbol] = min(lowestPrices[symbol]!, lastPrice);
      double stopPercent = getTrailingStop(symbol, true) / lastPrice;
      if (lastPrice > stopPercent || rsi > 60 || lastPrice > upperBB) {
        double quantity = shortPositionSizes[symbol]!;
        pendingTrades[symbol] = {'side': 'BUY', 'quantity': quantity, 'price': lastPrice, 'isShort': true};
        placeOrder('BUY', symbol, quantity);
        inShortPosition[symbol] = false;
        double tradePnl = quantity * (shortEntryPrices[symbol]! - lastPrice) * (1 - 0.004);
        capital += tradePnl;
        dailyPnl += tradePnl;
        if (tradePnl > 0) {
          tradesWon[symbol] = (tradesWon[symbol] ?? 0) + 1;
          totalGain[symbol] = (totalGain[symbol] ?? 0) + tradePnl;
        } else {
          tradesLost[symbol] = (tradesLost[symbol] ?? 0) + 1;
          totalLoss[symbol] = (totalLoss[symbol] ?? 0) + tradePnl.abs();
        }
        capitalHistory.add(capital);
        logs.add('SWING SHORT BUY $quantity $symbol @ $lastPrice (Stop)');
        String nextState = getState(symbol, false);
        updateQTable(state, action, tradePnl, nextState, false);
        shortPositionSizes.remove(symbol);
        saveState();
        pendingTrades.remove(symbol);
      }
    }
  }

  void dayTrade(String symbol) async {
    if (DateTime.now().day != lastDayTradeReset.day) {
      dailyDayTrades = 0;
      lastDayTradeReset = DateTime.now();
    }
    if (dailyPnl < -0.10 * capital || capital < 0.75 * initialCapital || !await healthCheck() || dailyDayTrades >= 25) return;
    double volatility15m = calculateVolatility15m(symbol);
    if (volatility15m > 0.05) {
      logs.add('$symbol 15m volatility >5% - pausing');
      return;
    }
    if (prices15m[symbol]!.length > 2 && prices15m[symbol]!.last / prices15m[symbol]![prices15m[symbol]!.length - 2] < 0.8) {
      logs.add('$symbol crashed >20% - pausing day trade');
      return;
    }

    var indicators = calculateIndicators(symbol, isDayTrade: true);
    double shortSMA = indicators['shortSMA']!;
    double longSMA = indicators['longSMA']!;
    double sma4h = indicators['sma4h']!;
    double sma1d = indicators['sma1d']!;
    double rsi = indicators['rsi']!;
    double upperBB = indicators['upperBB']!;
    double lowerBB = indicators['lowerBB']!;
    double lastPrice = lastPrices[symbol]!;
    double atr = atrs[symbol] ?? 0.0;
    double marketVolatility = calculateMarketVolatility();
    String state = getState(symbol, true);
    String action = chooseAction(state, true);
    double baseRisk = action == 'lowRisk' ? 0.01 : action == 'medRisk' ? 0.02 : 0.03 * (1 + newsSentiment.clamp(0, 1));
    double riskPerTrade = getDynamicRisk(symbol, true) * (action == 'lowRisk' ? 0.5 : action == 'medRisk' ? 1.0 : 1 + newsSentiment.clamp(0, 1));
    double sentiment = sentimentScores[symbol] ?? 0.0;
    double takeProfit = action == 'lowProfit' ? 0.05 : 0.07 + (atr / lastPrice) * (1 + newsSentiment.clamp(0, 1));
    double buyConfidence = predictBuyConfidence(symbol, isDayTrade: true);
    double btcAllocation = capital * 0.5;
    double topEmergingAllocation = capital * 0.3 / emergingCoins.length;
    double otherAllocation = capital * 0.2 / (prices.keys.length - emergingCoins.length - 1);

    inDayPosition[symbol] ??= false;
    dayHighestPrices[symbol] ??= lastPrice;

    if (!await checkLiquidity(symbol)) return;

    if (shortSMA > longSMA && sma4h < lastPrice && sma1d < lastPrice && rsi > 50 && rsi < 70 && lastPrice < lowerBB && !inDayPosition[symbol]! && sentiment > 0.6 && buyConfidence > 0.75) {
      double alloc = symbol == 'BTC-USD' ? btcAllocation : (emergingCoins.contains(symbol) ? topEmergingAllocation : otherAllocation);
      double quantity = (alloc * riskPerTrade) / lastPrice;
      if (quantity * lastPrice < 1.0) return;
      pendingTrades[symbol] = {'side': 'BUY', 'quantity': quantity, 'price': lastPrice};
      placeOrder('BUY', symbol, quantity);
      inDayPosition[symbol] = true;
      dayEntryPrices[symbol] = lastPrice;
      dayHighestPrices[symbol] = lastPrice;
      dayPositionSizes[symbol] = quantity;
      dailyDayTrades++;
      logs.add('DAY BUY $quantity $symbol @ $lastPrice (Confidence: ${buyConfidence.toStringAsFixed(2)})');
      pendingTrades.remove(symbol);
    } else if (inDayPosition[symbol]!) {
      double profitPercent = (lastPrice - dayEntryPrices[symbol]!) / dayEntryPrices[symbol]!;
      bool endOfDay = DateTime.now().toUtc().hour == 23 && DateTime.now().toUtc().minute >= 59;
      if (profitPercent >= takeProfit || lastPrice > upperBB || endOfDay) {
        double quantity = dayPositionSizes[symbol]!;
        pendingTrades[symbol] = {'side': 'SELL', 'quantity': quantity, 'price': lastPrice};
        placeOrder('SELL', symbol, quantity);
        inDayPosition[symbol] = false;
        double tradePnl = quantity * (lastPrice - dayEntryPrices[symbol]!) * (1 - 0.004);
        capital += quantity * lastPrice * (1 - 0.004);
        dailyPnl += tradePnl;
        if (tradePnl > 0) {
          tradesWon[symbol] = (tradesWon[symbol] ?? 0) + 1;
          totalGain[symbol] = (totalGain[symbol] ?? 0) + tradePnl;
        } else {
          tradesLost[symbol] = (tradesLost[symbol] ?? 0) + 1;
          totalLoss[symbol] = (totalLoss[symbol] ?? 0) + tradePnl.abs();
        }
        capitalHistory.add(capital);
        logs.add('DAY SELL $quantity $symbol @ $lastPrice (${endOfDay ? 'End of Day' : 'Take-Profit'})');
        String nextState = getState(symbol, true);
        updateQTable(state, action, tradePnl, nextState, true);
        dayPositionSizes.remove(symbol);
        saveState();
        pendingTrades.remove(symbol);
      }
      dayHighestPrices[symbol] = max(dayHighestPrices[symbol]!, lastPrice);
      double stopPercent = getTrailingStop(symbol, false) / lastPrice;
      if (lastPrice < stopPercent || lastPrice < dayHighestPrices[symbol]! * 0.98) {
        double quantity = dayPositionSizes[symbol]!;
        pendingTrades[symbol] = {'side': 'SELL', 'quantity': quantity, 'price': lastPrice};
        placeOrder('SELL', symbol, quantity);
        inDayPosition[symbol] = false;
        double tradePnl = quantity * (lastPrice - dayEntryPrices[symbol]!) * (1 - 0.004);
        capital += quantity * lastPrice * (1 - 0.004);
        dailyPnl += tradePnl;
        if (tradePnl > 0) {
          tradesWon[symbol] = (tradesWon[symbol] ?? 0) + 1;
          totalGain[symbol] = (totalGain[symbol] ?? 0) + tradePnl;
        } else {
          tradesLost[symbol] = (tradesLost[symbol] ?? 0) + 1;
          totalLoss[symbol] = (totalLoss[symbol] ?? 0) + tradePnl.abs();
        }
        capitalHistory.add(capital);
        logs.add('DAY SELL $quantity $symbol @ $lastPrice (Stop)');
        String nextState = getState(symbol, true);
        updateQTable(state, action, tradePnl, nextState, true);
        dayPositionSizes.remove(symbol);
        saveState();
        pendingTrades.remove(symbol);
      }
    }
  }

  Future<http.Response> queueApiCall(Future<http.Response> Function() call) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    apiQueue[now] = (apiQueue[now] ?? 0) + 1;
    if (apiQueue[now]! > 5) await Future.delayed(Duration(milliseconds: 1000));
    return call();
  }

  Future<void> placeOrder(String side, String symbol, double quantity, {int retries = 3}) async {
    final timestamp = (DateTime.now().millisecondsSinceEpoch / 1000).toString();
    final method = 'POST';
    final path = '/api/v3/brokerage/orders';
    final body = jsonEncode({
      'side': side.toLowerCase(),
      'product_id': symbol,
      'client_order_id': '${DateTime.now().millisecondsSinceEpoch}-${random.nextInt(1000)}',
      'order_configuration': {
        'market_market_ioc': {
          'quote_size': (quantity * lastPrices[symbol]!).toStringAsFixed(2),
        }
      }
    });
    final signature = signRequest(timestamp, method, path, body);

    for (int i = 0; i < retries; i++) {
      final response = await queueApiCall(() => http.post(
        Uri.parse('https://api.coinbase.com$path'),
        headers: {
          'CB-ACCESS-KEY': apiKey,
          'CB-ACCESS-SIGN': signature,
          'CB-ACCESS-TIMESTAMP': timestamp,
          'Content-Type': 'application/json',
        },
        body: body,
      ));

      if (response.statusCode == 200 || response.statusCode == 201) {
        capital += side == 'SELL' ? quantity * lastPrices[symbol]! * (1 - 0.004) : -quantity * lastPrices[symbol]! * (1 + 0.004);
        logs.add('$side $quantity $symbol executed');
        notify('$side $quantity $symbol', 'Trade executed successfully');
        return;
      } else {
        logs.add('Order failed: ${response.body} (Retry ${i + 1}/$retries)');
        await Future.delayed(Duration(seconds: 1));
      }
    }
    logs.add('$side $quantity $symbol failed after $retries retries');
    notify('Order Failed', '$side $quantity $symbol failed after $retries retries');
  }

  void manualTrade(String side, String symbol, {bool isDayTrade = false}) {
    double risk = getDynamicRisk(symbol, isDayTrade);
    double quantity = (capital * risk * 2.0) / lastPrices[symbol]!;
    if (quantity * lastPrices[symbol]! >= 1.0) placeOrder(side, symbol, quantity);
  }

  Future<void> notify(String title, String body) async {
    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    const android = AndroidNotificationDetails('channel_id', 'Trades', importance: Importance.max, priority: Priority.high);
    const platform = NotificationDetails(android: android);
    await flutterLocalNotificationsPlugin.show(0, title, body, platform);
  }
}

class TradingScreen extends StatefulWidget {
  @override
  _TradingScreenState createState() => _TradingScreenState();
}

class _TradingScreenState extends State<TradingScreen> {
  TradingLogic trader = TradingLogic();
  Map<String, WebSocketChannel> channels = {};
  Map<String, String> priceDisplays = {};
  bool liveTrading = false;
  bool dayTrading = false;
  double riskMultiplier = 2.0;

  @override
  void initState() {
    super.initState();
    trader.loadState().then((_) {
      setState(() {});
      for (var trade in trader.pendingTrades.entries) {
        trader.placeOrder(trade.value['side'].startsWith('DAY') ? trade.value['side'].substring(4) : trade.value['side'], trade.key, trade.value['quantity']);
      }
    });
    trader.detectEmergingCoins();
    connectToWebSocket('BTC-USD', false);
    connectToWebSocket('BTC-USD', true);
    connectToWebSocket('BTC-USD', false, true);
    connectToWebSocket('ETH-USD', false);
    connectToWebSocket('ETH-USD', true);
    connectToWebSocket('ETH-USD', false, true);
    connectToWebSocket('SOL-USD', false);
    connectToWebSocket('SOL-USD', true);
    connectToWebSocket('SOL-USD', false, true);
    Future.delayed(Duration(minutes: 5), () => trader.detectEmergingCoins());
    initializeNotifications();
    Future.delayed(Duration(minutes: 5), () async {
      while (mounted) {
        await trader.syncWithAccount();
        await Future.delayed(Duration(minutes: 5));
      }
    });
    Future.delayed(Duration(minutes: 15), () async {
      while (mounted) {
        await trader.fetchGovernmentFinancialNews();
        await Future.delayed(Duration(minutes: 15));
      }
    });
  }

  void initializeNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await FlutterLocalNotificationsPlugin().initialize(initSettings);
  }

  void connectToWebSocket(String symbol, bool is4h, [bool is15m = false]) {
    channels['$symbol-${is4h ? '4h' : is15m ? '15m' : '1h'}'] = WebSocketChannel.connect(Uri.parse('wss://ws-feed.coinbase.com'));
    channels['$symbol-${is4h ? '4h' : is15m ? '15m' : '1h'}']!.sink.add(jsonEncode({
      'type': 'subscribe',
      'product_ids': [symbol],
      'channels': [is4h || is15m ? 'matches' : 'ticker'],
    }));
    channels['$symbol-${is4h ? '4h' : is15m ? '15m' : '1h'}']!.stream.listen((data) {
      final jsonData = jsonDecode(data);
      if (jsonData['type'] == 'ticker' && !is4h && !is15m && liveTrading) {
        double price = double.parse(jsonData['price']);
        double volume = double.parse(jsonData['volume_24h'] ?? '0');
        setState(() {
          trader.updatePrice(symbol, price, volume, false, false);
          priceDisplays[symbol] = price.toStringAsFixed(2);
        });
        if (trader.emergingCoins.isNotEmpty && !channels.containsKey('${trader.emergingCoins.last}-1h')) {
          connectToWebSocket(trader.emergingCoins.last, false);
          connectToWebSocket(trader.emergingCoins.last, true);
          connectToWebSocket(trader.emergingCoins.last, false, true);
        }
      } else if (jsonData['type'] == 'match' && is4h && liveTrading && DateTime.now().minute % 240 == 0) {
        double price = double.parse(jsonData['price']);
        setState(() => trader.updatePrice(symbol, price, 0, true, false));
      } else if (jsonData['type'] == 'match' && is15m && dayTrading && DateTime.now().minute % 15 == 0) {
        double price = double.parse(jsonData['price']);
        setState(() => trader.updatePrice(symbol, price, 0, false, true));
      }
    }, onError: (error) {
      print('WebSocket error: $error');
      connectToWebSocket(symbol, is4h, is15m);
    });
  }

  void toggleLiveTrading() {
    setState(() {
      liveTrading = !liveTrading;
      trader.logs.add(liveTrading ? 'Swing trading activated' : 'Swing trading paused');
      if (!liveTrading && (trader.dailyPnl < -0.10 * trader.capital || trader.capital < 0.75 * trader.initialCapital)) {
        trader.notify('Swing Trading Halted', 'Daily loss >10% or capital <\$750');
      }
    });
  }

  void toggleDayTrading() {
    setState(() {
      dayTrading = !dayTrading;
      trader.logs.add(dayTrading ? 'Day trading activated' : 'Day trading paused');
      if (!dayTrading && (trader.dailyPnl < -0.10 * trader.capital || trader.capital < 0.75 * trader.initialCapital)) {
        trader.notify('Day Trading Halted', 'Daily loss >10% or capital <\$750');
      }
    });
  }

  @override
  void dispose() {
    channels.forEach((_, channel) => channel.sink.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double winRate = trader.tradesWon.values.fold(0, (a, b) => a + b) / (trader.tradesWon.values.fold(0, (a, b) => a + b) + trader.tradesLost.values.fold(0, (a, b) => a + b)).clamp(0, 1) * 100;
    double avgGain = trader.totalGain.values.fold(0.0, (a, b) => a + b) / trader.tradesWon.values.fold(0, (a, b) => a + b).clamp(1, double.infinity);
    double avgLoss = trader.totalLoss.values.fold(0.0, (a, b) => a + b) / trader.tradesLost.values.fold(0, (a, b) => a + b).clamp(1, double.infinity);

    return Scaffold(
      appBar: AppBar(title: Text('Coinbase Elite Trader', style: TextStyle(fontWeight: FontWeight.bold))),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Card(
              margin: EdgeInsets.all(8),
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Column(
                  children: [
                    Text('Capital: \$${trader.capital.toStringAsFixed(2)}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('Daily PnL: \$${trader.dailyPnl.toStringAsFixed(2)}', style: TextStyle(fontSize: 16, color: trader.dailyPnl >= 0 ? Colors.green : Colors.red)),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton(onPressed: toggleLiveTrading, child: Text(liveTrading ? 'Pause Swing' : 'Start Swing')),
                        SizedBox(width: 10),
                        ElevatedButton(onPressed: toggleDayTrading, child: Text(dayTrading ? 'Pause Day' : 'Start Day')),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton(onPressed: () => trader.manualTrade('BUY', 'BTC-USD'), child: Text('Swing Buy BTC')),
                        SizedBox(width: 10),
                        ElevatedButton(onPressed: () => trader.manualTrade('SELL', 'BTC-USD'), child: Text('Swing Sell BTC')),
                        SizedBox(width: 10),
                        ElevatedButton(onPressed: () => trader.manualTrade('BUY', 'BTC-USD', isDayTrade: true), child: Text('Day Buy BTC')),
                        SizedBox(width: 10),
                        ElevatedButton(onPressed: () => trader.manualTrade('SELL', 'BTC-USD', isDayTrade: true), child: Text('Day Sell BTC')),
                      ],
                    ),
                    Slider(
                      value: riskMultiplier,
                      min: 0.5,
                      max: 2.0,
                      divisions: 15,
                      label: riskMultiplier.toStringAsFixed(1),
                      onChanged: (value) => setState(() => riskMultiplier = value),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              margin: EdgeInsets.all(8),
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Column(
                  children: [
                    Text('Capital Growth', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    SizedBox(
                      height: 200,
                      child: LineChart(
                        LineChartData(
                          gridData: FlGridData(show: true),
                          titlesData: FlTitlesData(
                            leftTitles: SideTitles(show: true, getTitles: (value) => '\$${value.toStringAsFixed(0)}'),
                            bottomTitles: SideTitles(show: true, getTitles: (value) => value.toInt() % 10 == 0 ? value.toInt().toString() : ''),
                          ),
                          borderData: FlBorderData(show: true),
                          minX: 0,
                          maxX: trader.capitalHistory.length.toDouble() - 1,
                          minY: 500,
                          maxY: trader.capitalHistory.reduce(max) * 1.1,
                          lineBarsData: [
                            LineChartBarData(
                              spots: trader.capitalHistory.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList(),
                              isCurved: true,
                              colors: [Colors.blue],
                              dotData: FlDotData(show: false),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              margin: EdgeInsets.all(8),
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Column(
                  children: [
                    Text('Performance', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    Text('Win Rate: ${winRate.toStringAsFixed(1)}%'),
                    Text('Avg Gain: \$${avgGain.toStringAsFixed(2)}'),
                    Text('Avg Loss: \$${avgLoss.toStringAsFixed(2)}'),
                    Text('Daily Day Trades: ${trader.dailyDayTrades}/25'),
                  ],
                ),
              ),
            ),
            Card(
              margin: EdgeInsets.all(8),
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Column(
                  children: [
                    Text('Active Positions', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    Text('Swing Trades:'),
                    ...trader.inPosition.entries.where((e) => e.value).map((e) => Text('${e.key}: ${trader.positionSizes[e.key]!.toStringAsFixed(8)} @ \$${trader.entryPrices[e.key]!.toStringAsFixed(2)}')),
                    Text('Short Swing Trades:'),
                    ...trader.inShortPosition.entries.where((e) => e.value).map((e) => Text('${e.key}: ${trader.shortPositionSizes[e.key]!.toStringAsFixed(8)} @ \$${trader.shortEntryPrices[e.key]!.toStringAsFixed(2)}')),
                    Text('Day Trades:'),
                    ...trader.inDayPosition.entries.where((e) => e.value).map((e) => Text('${e.key}: ${trader.dayPositionSizes[e.key]!.toStringAsFixed(8)} @ \$${trader.dayEntryPrices[e.key]!.toStringAsFixed(2)}')),
                  ],
                ),
              ),
            ),
            Card(
              margin: EdgeInsets.all(8),
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Column(
                  children: [
                    Text('Monitored Coins', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ...priceDisplays.entries.map((e) => Text('${e.key}: \$${e.value} (Sentiment: ${trader.sentimentScores[e.key]?.toStringAsFixed(2) ?? 0})')),
                    Text('Emerging Coins: ${trader.emergingCoins.join(", ")}'),
                  ],
                ),
              ),
            ),
            Card(
              margin: EdgeInsets.all(8),
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Column(
                  children: [
                    Text('Logs (Last 20)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    SizedBox(
                      height: 100,
                      child: ListView.builder(
                        itemCount: trader.logs.length > 20 ? 20 : trader.logs.length,
                        itemBuilder: (context, index) => Text(trader.logs[trader.logs.length - 1 - index], style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  runApp(MaterialApp(home: TradingScreen()));
}
