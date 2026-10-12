
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const PoeProfitApp());
}

const Color backgroundColor = Color(0xFF101116);
const Color surfaceColor = Color(0xFF191B23);
const Color borderColor = Color(0xFF30323D);
const Color accentColor = Color(0xFFE8B45A);
const Color greenColor = Color(0xFF54D69A);
const Color redColor = Color(0xFFFF7373);
const Color secondaryTextColor = Color(0xFF9A9DAC);

const String poeNinjaBase = '/api/poe';

double numberOf(String value) =>
    double.tryParse(value.trim()) ?? 0;

String formatNumber(double value, {int decimals = 1}) =>
    value.toStringAsFixed(decimals);

class MarketItem {
  final String name;
  final double chaosValue;
  final String category;

  const MarketItem({
    required this.name,
    required this.chaosValue,
    required this.category,
  });
}

class PoePriceService {
  PoePriceService._();

  static final PoePriceService instance = PoePriceService._();

  final http.Client _client = http.Client();
  final Map<String, List<MarketItem>> _cache = {};
  final Map<String, DateTime> _cacheTime = {};

  List<String> leagues = [];
  String? currentLeague;

  static const Duration cacheDuration = Duration(minutes: 10);

  // Categories supported by poe.ninja's exchange overview endpoint.
  static const Map<String, String> exchangeTypes = {
    'Currency': 'Currency',
    'Fragments': 'Fragment',
    'Scarabs': 'Scarab',
    'Divination Cards': 'DivinationCard',
    'Essences': 'Essence',
    'Fossils': 'Fossil',
    'Oils': 'Oil',
    'Delirium Orbs': 'DeliriumOrb',
  };

  // Categories supported by poe.ninja's stash item overview endpoint.
  static const Map<String, String> categories = {
    'Currency': 'Currency',
    'Fragments': 'Fragment',
    'Scarabs': 'Scarab',
    'Maps': 'Map',
    'Unique Maps': 'UniqueMap',
    'Divination Cards': 'DivinationCard',
    'Essences': 'Essence',
    'Fossils': 'Fossil',
    'Oils': 'Oil',
    'Skill Gems': 'SkillGem',
    'Unique Weapons': 'UniqueWeapon',
    'Unique Armour': 'UniqueArmour',
    'Unique Accessories': 'UniqueAccessory',
    'Unique Flasks': 'UniqueFlask',
    'Unique Jewels': 'UniqueJewel',
    'Delirium Orbs': 'DeliriumOrb',
    'Invitations': 'Invitation',
  };

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String> queryParameters = const {},
  }) async {
    final uri = Uri.parse('$poeNinjaBase/$path').replace(
      queryParameters:
          queryParameters.isEmpty ? null : queryParameters,
    );

    final response = await _client
        .get(
          uri,
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      final responseBody = response.body.length > 300
          ? response.body.substring(0, 300)
          : response.body;

      throw Exception(
        'API request failed: HTTP ${response.statusCode} '
        'at ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}. '
        '$responseBody',
      );
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map<String, dynamic>) {
      throw Exception('Unexpected API response from ${uri.path}.');
    }

    return decoded;
  }

  Future<void> loadLeagues({bool force = false}) async {
    if (!force && leagues.isNotEmpty) return;

    final uri = Uri.parse('$poeNinjaBase/leagues');

    final response = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception(
        'Could not load Path of Exile leagues '
        '(HTTP ${response.statusCode}).',
      );
    }

    final data = jsonDecode(response.body);

    if (data is! List) {
      throw Exception('Unexpected league response.');
    }

    leagues = data
        .whereType<Map>()
        .map((entry) => entry['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .toList();

    if (leagues.isEmpty) {
      throw Exception('No leagues were returned by poe.ninja.');
    }

    if (currentLeague == null || !leagues.contains(currentLeague)) {
      currentLeague = leagues.first;
    }
  }

  Future<List<MarketItem>> _fetchCategory(
    String league,
    String category,
    String type,
  ) async {
    final key = '$league:$category';

    final cached = _cache[key];
    final cachedAt = _cacheTime[key];

    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < cacheDuration) {
      return cached;
    }

    final List<MarketItem> items;

    if (exchangeTypes.containsKey(category)) {
      items = await _fetchExchangeCategory(
        league,
        category,
        exchangeTypes[category]!,
      );
    } else {
      items = await _fetchStashCategory(
        league,
        category,
        type,
      );
    }

    _cache[key] = items;
    _cacheTime[key] = DateTime.now();

    return items;
  }

  Future<List<MarketItem>> _fetchExchangeCategory(
    String league,
    String category,
    String type,
  ) async {
    final data = await _getJson(
      'exchange/current/overview',
      queryParameters: {
        'league': league,
        'type': type,
      },
    );

    final rawLines = data['lines'];

    if (rawLines is! List) {
      throw Exception(
        'Unexpected exchange response for $category: missing lines.',
      );
    }

    final core = data['core'] is Map
        ? Map<String, dynamic>.from(data['core'] as Map)
        : <String, dynamic>{};

    // The exchange response contains item metadata separately from
    // its price lines. Match the line ID with the metadata ID.
    final Map<String, Map<String, dynamic>> itemsById = {};
    final rawItems = core['items'];

    if (rawItems is List) {
      for (final rawItem in rawItems) {
        if (rawItem is! Map) continue;

        final item = Map<String, dynamic>.from(rawItem);
        final id = item['id']?.toString();

        if (id != null && id.isNotEmpty) {
          itemsById[id] = item;
        }
      }
    } else if (rawItems is Map) {
      rawItems.forEach((key, value) {
        if (value is Map) {
          itemsById[key.toString()] =
              Map<String, dynamic>.from(value);
        }
      });
    }

    final results = <MarketItem>[];

    for (final rawLine in rawLines) {
      if (rawLine is! Map) continue;

      final line = Map<String, dynamic>.from(rawLine);
      final id = line['id']?.toString() ?? '';
      final metadata = itemsById[id];

      final name = metadata?['name']?.toString() ??
          line['name']?.toString() ??
          '';

      // poe.ninja exchange overview prices are expressed in the
      // primary reference currency reported by the API.
      final rawPrice = line['primaryValue'];
      final price = rawPrice is num
          ? rawPrice.toDouble()
          : double.tryParse(rawPrice?.toString() ?? '') ?? 0;

      if (name.isEmpty || price <= 0) continue;

      results.add(
        MarketItem(
          name: name,
          chaosValue: price,
          category: category,
        ),
      );
    }

    return results;
  }

  Future<List<MarketItem>> _fetchStashCategory(
    String league,
    String category,
    String type,
  ) async {
    final data = await _getJson(
      'stash/current/item/overview',
      queryParameters: {
        'league': league,
        'type': type,
      },
    );

    final rawLines = data['lines'];

    if (rawLines is! List) {
      throw Exception(
        'Unexpected stash response for $category: missing lines.',
      );
    }

    final results = <MarketItem>[];

    for (final rawLine in rawLines) {
      if (rawLine is! Map) continue;

      final line = Map<String, dynamic>.from(rawLine);
      final name = line['name']?.toString() ?? '';

      final rawPrice = line['chaosValue'];
      final price = rawPrice is num
          ? rawPrice.toDouble()
          : double.tryParse(rawPrice?.toString() ?? '') ?? 0;

      if (name.isEmpty || price <= 0) continue;

      results.add(
        MarketItem(
          name: name,
          chaosValue: price,
          category: category,
        ),
      );
    }

    return results;
  }

  Future<List<MarketItem>> searchItems(
    String query, {
    String? category,
  }) async {
    if (currentLeague == null) {
      await loadLeagues();
    }

    final league = currentLeague!;

    final selectedCategories = category == null
        ? categories.entries.toList()
        : categories.entries
            .where((entry) => entry.key == category)
            .toList();

    final results = await Future.wait(
      selectedCategories.map(
        (entry) => _fetchCategory(
          league,
          entry.key,
          entry.value,
        ),
      ),
    );

    final allItems = results.expand((items) => items).toList();
    final normalizedQuery = query.trim().toLowerCase();

    if (normalizedQuery.isEmpty) {
      return allItems.take(50).toList();
    }

    final matches = allItems
        .where(
          (item) => item.name.toLowerCase().contains(normalizedQuery),
        )
        .toList();

    matches.sort((a, b) {
      final aName = a.name.toLowerCase();
      final bName = b.name.toLowerCase();

      final aExact = aName == normalizedQuery;
      final bExact = bName == normalizedQuery;

      if (aExact != bExact) return aExact ? -1 : 1;

      final aStarts = aName.startsWith(normalizedQuery);
      final bStarts = bName.startsWith(normalizedQuery);

      if (aStarts != bStarts) return aStarts ? -1 : 1;

      return a.name.compareTo(b.name);
    });

    return matches.take(30).toList();
  }

  Future<void> refreshPrices() async {
    _cache.clear();
    _cacheTime.clear();
    await loadLeagues(force: true);
  }

  void dispose() {
    _client.close();
  }
}

class InvestmentItem {
  InvestmentItem({
    String name = '',
    String quantity = '1',
    String price = '0',
  })  : name = TextEditingController(text: name),
        quantity = TextEditingController(text: quantity),
        price = TextEditingController(text: price);

  final TextEditingController name;
  final TextEditingController quantity;
  final TextEditingController price;
  MarketItem? marketItem;

  double get total => numberOf(quantity.text) * numberOf(price.text);

  void dispose() {
    name.dispose();
    quantity.dispose();
    price.dispose();
  }
}

class LootItem {
  LootItem({
    String name = '',
    String price = '0',
    String chance = '100',
    String quantity = '1',
  })  : name = TextEditingController(text: name),
        price = TextEditingController(text: price),
        chance = TextEditingController(text: chance),
        quantity = TextEditingController(text: quantity);

  final TextEditingController name;
  final TextEditingController price;
  final TextEditingController chance;
  final TextEditingController quantity;
  MarketItem? marketItem;

  double get expectedValue {
    final probability = numberOf(chance.text).clamp(0.0, 100.0) / 100;
    return probability * numberOf(quantity.text) * numberOf(price.text);
  }

  void dispose() {
    name.dispose();
    price.dispose();
    chance.dispose();
    quantity.dispose();
  }
}

class PoeProfitApp extends StatelessWidget {
  const PoeProfitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Exile Profit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: backgroundColor,
        colorScheme: const ColorScheme.dark(
          primary: accentColor,
          secondary: greenColor,
          surface: surfaceColor,
          error: redColor,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: backgroundColor,
          hintStyle: const TextStyle(color: secondaryTextColor),
          labelStyle: const TextStyle(color: secondaryTextColor),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 13,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: borderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: borderColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: accentColor),
          ),
        ),
      ),
      home: const CalculatorPage(),
    );
  }
}

class CalculatorPage extends StatefulWidget {
  const CalculatorPage({super.key});

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  final strategyController =
      TextEditingController(text: 'Standard Map Farming');
  final mapController = TextEditingController(text: 'T16 Map');
  final mapTimeController = TextEditingController(text: '4');
  final extraTimeController = TextEditingController(text: '0');

  final api = PoePriceService.instance;

  List<String> get leagues => api.leagues;

  String? get currentLeague => api.currentLeague;

  bool loadingPrices = false;
  String? apiError;
  DateTime? lastRefresh;

  final List<InvestmentItem> investments = [
    InvestmentItem(name: 'Map', quantity: '1', price: '5'),
    InvestmentItem(name: 'Scarabs', quantity: '3', price: '8'),
    InvestmentItem(name: 'Map Crafting', quantity: '1', price: '4'),
    InvestmentItem(name: 'Other Consumables', quantity: '1', price: '2'),
  ];

  final List<LootItem> loot = [
    LootItem(name: 'Common Loot', price: '20', chance: '100'),
    LootItem(name: 'Valuable Item', price: '80', chance: '25'),
    LootItem(name: 'Rare Drop', price: '200', chance: '5'),
  ];

  double get totalInvestment =>
      investments.fold(0, (sum, item) => sum + item.total);

  double get expectedRevenue =>
      loot.fold(0, (sum, item) => sum + item.expectedValue);

  double get netProfit => expectedRevenue - totalInvestment;

  double get totalMapTime =>
      numberOf(mapTimeController.text) + numberOf(extraTimeController.text);

  double get mapsPerHour => totalMapTime > 0 ? 60 / totalMapTime : 0;

  double get profitPerHour => netProfit * mapsPerHour;

  double get revenuePerHour => expectedRevenue * mapsPerHour;

  double get investmentPerHour => totalInvestment * mapsPerHour;

  @override
  void initState() {
    super.initState();
    _loadInitialLeague();
  }

  Future<void> _loadInitialLeague() async {
    setState(() {
      loadingPrices = true;
      apiError = null;
    });

    try {
      await api.loadLeagues();

      if (!mounted) return;

      setState(() {
        loadingPrices = false;
        lastRefresh = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loadingPrices = false;
        apiError = _friendlyError(e);
      });
    }
  }

  String _friendlyError(Object error) {
    final message = error.toString();

    if (message.contains('Failed to fetch') ||
        message.contains('XMLHttpRequest') ||
        message.contains('ClientException')) {
      return 'API request failed. The browser may be blocking the request '
          'because of CORS, or the network is unavailable.';
    }

    return message.replaceFirst('Exception: ', '');
  }

  Future<void> _refreshPrices() async {
    setState(() {
      loadingPrices = true;
      apiError = null;
    });

    try {
      await api.refreshPrices();

      if (!mounted) return;

      setState(() {
        loadingPrices = false;
        lastRefresh = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loadingPrices = false;
        apiError = _friendlyError(e);
      });
    }
  }

  Future<void> _changeLeague(String? league) async {
    if (league == null || league == currentLeague) return;

    setState(() {
      api.currentLeague = league;
      loadingPrices = true;
      apiError = null;
    });

    if (!mounted) return;

    setState(() {
      loadingPrices = false;
    });
  }

  Future<void> _selectInvestment(
    InvestmentItem item,
    MarketItem market,
  ) async {
    setState(() {
      item.marketItem = market;
      item.name.text = market.name;
      item.price.text = formatNumber(market.chaosValue, decimals: 2);
    });
  }

  Future<void> _selectLoot(LootItem item, MarketItem market) async {
    setState(() {
      item.marketItem = market;
      item.name.text = market.name;
      item.price.text = formatNumber(market.chaosValue, decimals: 2);
    });
  }

  @override
  void dispose() {
    strategyController.dispose();
    mapController.dispose();
    mapTimeController.dispose();
    extraTimeController.dispose();

    for (final item in investments) {
      item.dispose();
    }

    for (final item in loot) {
      item.dispose();
    }

    super.dispose();
  }

  void refresh() => setState(() {});

  void addInvestment() {
    setState(() => investments.add(InvestmentItem(name: '')));
  }

  void removeInvestment(int index) {
    setState(() => investments.removeAt(index).dispose());
  }

  void addLoot() {
    setState(() => loot.add(LootItem(name: '')));
  }

  void removeLoot(int index) {
    setState(() => loot.removeAt(index).dispose());
  }

  void resetCalculator() {
    for (final item in investments) {
      item.dispose();
    }
    for (final item in loot) {
      item.dispose();
    }

    setState(() {
      strategyController.text = 'Standard Map Farming';
      mapController.text = 'T16 Map';
      mapTimeController.text = '4';
      extraTimeController.text = '0';

      investments
        ..clear()
        ..addAll([
          InvestmentItem(name: 'Map', price: '5'),
          InvestmentItem(name: 'Scarabs', quantity: '3', price: '8'),
          InvestmentItem(name: 'Map Crafting', price: '4'),
          InvestmentItem(name: 'Other Consumables', price: '2'),
        ]);

      loot
        ..clear()
        ..addAll([
          LootItem(name: 'Common Loot', price: '20'),
          LootItem(name: 'Valuable Item', price: '80', chance: '25'),
          LootItem(name: 'Rare Drop', price: '200', chance: '5'),
        ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: backgroundColor,
        surfaceTintColor: Colors.transparent,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt, color: accentColor, size: 27),
            SizedBox(width: 8),
            Text(
              'EXILE PROFIT',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: 1.3,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh API prices',
            onPressed: loadingPrices ? null : _refreshPrices,
            icon: loadingPrices
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
          ),
          TextButton.icon(
            onPressed: resetCalculator,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Reset'),
          ),
          const SizedBox(width: 12),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: borderColor),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1000;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1400),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'FARMING CALCULATOR',
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Calculate your profit.',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Estimate your Chaos per hour using your investment, '
                      'drop chances, and map completion time.',
                      style: TextStyle(
                        color: secondaryTextColor,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _buildApiStatus(),
                    const SizedBox(height: 20),
                    _buildStrategySection(),
                    const SizedBox(height: 20),
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _buildInvestmentSection()),
                          const SizedBox(width: 20),
                          Expanded(child: _buildLootSection()),
                        ],
                      )
                    else ...[
                      _buildInvestmentSection(),
                      const SizedBox(height: 20),
                      _buildLootSection(),
                    ],
                    const SizedBox(height: 20),
                    _buildResultsSection(),
                    const SizedBox(height: 24),
                    const Center(
                      child: Text(
                        'EXPECTED VALUES ONLY • LIVE POE.NINJA PRICES',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 10,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildApiStatus() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                apiError == null ? Icons.cloud_done : Icons.cloud_off,
                color: apiError == null ? greenColor : redColor,
                size: 20,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'POE.NINJA MARKET DATA',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              if (loadingPrices)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (leagues.isNotEmpty)
            Row(
              children: [
                const Text(
                  'League',
                  style: TextStyle(color: secondaryTextColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: currentLeague,
                    isExpanded: true,
                    decoration: const InputDecoration(isDense: true),
                    items: leagues
                        .map(
                          (league) => DropdownMenuItem(
                            value: league,
                            child: Text(league),
                          ),
                        )
                        .toList(),
                    onChanged: loadingPrices ? null : _changeLeague,
                  ),
                ),
              ],
            ),
          if (apiError != null) ...[
            const SizedBox(height: 10),
            Text(
              apiError!,
              style: const TextStyle(color: redColor, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: loadingPrices ? null : _refreshPrices,
                child: const Text('Retry'),
              ),
            ),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              lastRefresh == null
                  ? 'Select an item to load its market price.'
                  : 'League detected. Last refresh: '
                      '${lastRefresh!.toLocal().toString().substring(11, 19)}',
              style: const TextStyle(
                color: secondaryTextColor,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStrategySection() {
    return _sectionCard(
      title: 'Strategy Settings',
      subtitle: 'Define your farming session.',
      icon: Icons.tune,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fields = [
            _field(
              label: 'Strategy Name',
              controller: strategyController,
              numeric: false,
            ),
            _field(
              label: 'Map',
              controller: mapController,
              numeric: false,
            ),
            _field(label: 'Map Time (minutes)', controller: mapTimeController),
            _field(
              label: 'Extra Time (minutes)',
              controller: extraTimeController,
            ),
          ];

          if (constraints.maxWidth < 520) {
            return Column(
              children: [
                for (int i = 0; i < fields.length; i++) ...[
                  fields[i],
                  if (i < fields.length - 1) const SizedBox(height: 14),
                ],
              ],
            );
          }

          return Row(
            children: [
              for (int i = 0; i < fields.length; i++) ...[
                Expanded(child: fields[i]),
                if (i < fields.length - 1) const SizedBox(width: 12),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildInvestmentSection() {
    return _sectionCard(
      title: 'Investment',
      subtitle: 'Your cost per map, in Chaos Orbs.',
      icon: Icons.shopping_cart_outlined,
      trailing: _addButton('Add Cost', addInvestment),
      child: Column(
        children: [
          if (investments.isEmpty)
            const Text(
              'No costs added.',
              style: TextStyle(color: secondaryTextColor),
            ),
          for (int i = 0; i < investments.length; i++)
            _buildInvestmentRow(i, investments[i]),
          const Divider(color: borderColor, height: 28),
          _summaryRow(
            'Total Investment',
            '${formatNumber(totalInvestment)} c',
            valueColor: accentColor,
          ),
        ],
      ),
    );
  }

  Widget _buildInvestmentRow(int index, InvestmentItem item) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 480;

          final name = _marketItemField(
            label: 'Item / Cost',
            controller: item.name,
            onSelected: (market) => _selectInvestment(item, market),
          );

          final quantity = _field(
            label: 'Qty',
            controller: item.quantity,
          );

          final price = _field(
            label: 'Unit Price (c)',
            controller: item.price,
          );

          final total = _totalLabel('TOTAL', item.total, accentColor);

          final delete = IconButton(
            onPressed: () => removeInvestment(index),
            tooltip: 'Remove cost',
            icon: const Icon(Icons.close, size: 18),
          );

          if (compact) {
            return Column(
              children: [
                name,
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: quantity),
                    const SizedBox(width: 8),
                    Expanded(child: price),
                    const SizedBox(width: 8),
                    total,
                    delete,
                  ],
                ),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(flex: 4, child: name),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: quantity),
              const SizedBox(width: 8),
              Expanded(flex: 3, child: price),
              const SizedBox(width: 8),
              total,
              delete,
            ],
          );
        },
      ),
    );
  }

  Widget _buildLootSection() {
    return _sectionCard(
      title: 'Expected Loot',
      subtitle: 'Estimate average drops and their market value.',
      icon: Icons.inventory_2_outlined,
      trailing: _addButton('Add Loot', addLoot),
      child: Column(
        children: [
          if (loot.isEmpty)
            const Text(
              'No loot items added.',
              style: TextStyle(color: secondaryTextColor),
            ),
          for (int i = 0; i < loot.length; i++) _buildLootRow(i, loot[i]),
          const Divider(color: borderColor, height: 28),
          _summaryRow(
            'Expected Revenue',
            '${formatNumber(expectedRevenue)} c',
            valueColor: greenColor,
          ),
          const SizedBox(height: 6),
          const Text(
            'Expected value = drop chance × quantity per drop × unit price.',
            style: TextStyle(color: secondaryTextColor, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildLootRow(int index, LootItem item) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 480;

          final name = _marketItemField(
            label: 'Loot Item',
            controller: item.name,
            onSelected: (market) => _selectLoot(item, market),
          );

          final price = _field(
            label: 'Price (c)',
            controller: item.price,
          );

          final chance = _field(
            label: 'Chance (%)',
            controller: item.chance,
          );

          final quantity = _field(
            label: 'Qty per Drop',
            controller: item.quantity,
          );

          final expected = _totalLabel(
            'EXPECTED',
            item.expectedValue,
            greenColor,
          );

          final delete = IconButton(
            onPressed: () => removeLoot(index),
            tooltip: 'Remove loot',
            icon: const Icon(Icons.close, size: 18),
          );

          if (compact) {
            return Column(
              children: [
                name,
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: price),
                    const SizedBox(width: 8),
                    Expanded(child: chance),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: quantity),
                    const SizedBox(width: 8),
                    expected,
                    delete,
                  ],
                ),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(flex: 4, child: name),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: price),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: chance),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: quantity),
              const SizedBox(width: 8),
              expected,
              delete,
            ],
          );
        },
      ),
    );
  }

  Widget _marketItemField({
    required String label,
    required TextEditingController controller,
    required ValueChanged<MarketItem> onSelected,
  }) {
    return Autocomplete<MarketItem>(
      displayStringForOption: (item) => item.name,
      optionsBuilder: (textEditingValue) async {
        final query = textEditingValue.text.trim();

        if (query.length < 2) {
          return const <MarketItem>[];
        }

        try {
          return await api.searchItems(query);
        } catch (e) {
          if (mounted) {
            setState(() => apiError = _friendlyError(e));
          }

          return const <MarketItem>[];
        }
      },
      onSelected: (market) {
        controller.text = market.name;
        onSelected(market);
      },
      fieldViewBuilder: (
        context,
        textController,
        focusNode,
        onFieldSubmitted,
      ) {
        if (textController.text != controller.text &&
            !focusNode.hasFocus) {
          textController.value = controller.value;
        }

        return TextField(
          controller: textController,
          focusNode: focusNode,
          onChanged: (value) {
            if (controller.text != value) {
              controller.value = textController.value;
            }

            refresh();
          },
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            labelText: label,
            hintText: 'Type at least 2 characters',
            isDense: true,
            suffixIcon: const Icon(Icons.search, size: 18),
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final items = options.toList();

        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            color: surfaceColor,
            elevation: 8,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxHeight: 280,
                maxWidth: 420,
              ),
              child: ListView.separated(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: borderColor),
                itemBuilder: (context, index) {
                  final item = items[index];

                  return ListTile(
                    dense: true,
                    title: Text(
                      item.name,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      item.category,
                      style: const TextStyle(
                        color: secondaryTextColor,
                        fontSize: 11,
                      ),
                    ),
                    trailing: Text(
                      '${formatNumber(item.chaosValue, decimals: 2)} c',
                      style: const TextStyle(
                        color: accentColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onTap: () => onSelected(item),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildResultsSection() {
    final profitable = netProfit >= 0;
    final hasValidTime = totalMapTime > 0;

    return _sectionCard(
      title: 'Profitability Results',
      subtitle: 'Expected returns based on your current inputs.',
      icon: Icons.analytics_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: profitable
                  ? greenColor.withOpacity(0.08)
                  : redColor.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: profitable
                    ? greenColor.withOpacity(0.35)
                    : redColor.withOpacity(0.35),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'EXPECTED NET PROFIT',
                  style: TextStyle(
                    color: secondaryTextColor,
                    fontSize: 11,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  hasValidTime
                      ? '${formatNumber(profitPerHour, decimals: 0)} Chaos / hour'
                      : 'Enter a valid map time',
                  style: TextStyle(
                    color: profitable ? greenColor : redColor,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${strategyController.text.isEmpty ? 'Untitled Strategy' : strategyController.text} · '
                  '${mapController.text.isEmpty ? 'No Map Selected' : mapController.text}',
                  style: const TextStyle(
                    color: secondaryTextColor,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth < 520 ? 2 : 4;
              final width =
                  (constraints.maxWidth - (columns - 1) * 10) / columns;

              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  SizedBox(
                    width: width,
                    child: _metricCard(
                      'Net / Map',
                      '${formatNumber(netProfit)} c',
                      netProfit >= 0 ? greenColor : redColor,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _metricCard(
                      'Revenue / Hour',
                      '${formatNumber(revenuePerHour, decimals: 0)} c',
                      greenColor,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _metricCard(
                      'Investment / Hour',
                      '${formatNumber(investmentPerHour, decimals: 0)} c',
                      accentColor,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _metricCard(
                      'Maps / Hour',
                      hasValidTime ? formatNumber(mapsPerHour) : '—',
                      Colors.white,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          const Divider(color: borderColor),
          const SizedBox(height: 8),
          _summaryRow(
            'Expected revenue per map',
            '${formatNumber(expectedRevenue)} c',
          ),
          _summaryRow(
            'Total investment per map',
            '${formatNumber(totalInvestment)} c',
          ),
          _summaryRow(
            'Total map time',
            '${formatNumber(totalMapTime)} minutes',
          ),
          _summaryRow(
            'Break-even revenue per map',
            '${formatNumber(totalInvestment)} c',
          ),
          const SizedBox(height: 12),
          const Text(
            'Results are mathematical expectations, not guaranteed returns. '
            'Actual loot varies due to randomness, market prices, and '
            'farming efficiency.',
            style: TextStyle(
              color: secondaryTextColor,
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    Widget? trailing,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: accentColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: secondaryTextColor,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 22),
          child,
        ],
      ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    String hint = '',
    bool numeric = true,
  }) {
    return TextField(
      controller: controller,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      inputFormatters: numeric
          ? [
              FilteringTextInputFormatter.allow(
                RegExp(r'^\d*\.?\d*'),
              ),
            ]
          : null,
      onChanged: (_) => refresh(),
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
      ),
    );
  }

  Widget _totalLabel(String label, double value, Color color) {
    return SizedBox(
      width: 86,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: secondaryTextColor,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${formatNumber(value)} c',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _addButton(String label, VoidCallback onPressed) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.add, size: 17),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: accentColor,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _summaryRow(
    String label,
    String value, {
    Color valueColor = Colors.white,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: secondaryTextColor,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              color: valueColor,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: secondaryTextColor,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
