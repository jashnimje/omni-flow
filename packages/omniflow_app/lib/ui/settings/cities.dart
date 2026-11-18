import 'dart:math' as math;

/// A city home can be in, with where it is. North and east are positive.
class City {
  const City(
    this.name,
    this.country,
    this.latitude,
    this.longitude, [
    this.otherNames = const [],
  ]);

  final String name;
  final String country;
  final double latitude;
  final double longitude;

  /// Other names people search by, such as Bangalore for Bengaluru.
  final List<String> otherNames;

  /// "Bengaluru, India", as the Home location row shows it.
  String get label => '$name, $country';

  /// Distance in kilometres to [latitude2], [longitude2], on a round earth.
  double kmTo(double latitude2, double longitude2) {
    const r = 6371.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(latitude2 - latitude);
    final dLon = rad(longitude2 - longitude);
    final a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(latitude)) *
            math.cos(rad(latitude2)) *
            math.pow(math.sin(dLon / 2), 2);
    return 2 * r * math.asin(math.sqrt(a));
  }
}

/// The cities [query] finds: a name starting with it first, then a word of
/// a name, then the country. At most [limit].
List<City> searchCities(String query, {int limit = 8}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  int? rank(City c) {
    final names = [c.name, ...c.otherNames].map((n) => n.toLowerCase());
    if (names.any((n) => n.startsWith(q))) return 0;
    if (names.any(
      (n) => n.split(RegExp(r'[\s-]')).any((w) => w.startsWith(q)),
    )) {
      return 1;
    }
    if (c.country.toLowerCase().startsWith(q)) return 2;
    if (names.any((n) => n.contains(q))) return 3;
    return null;
  }

  final hits = <(int, City)>[
    for (final c in cities)
      if (rank(c) case final r?) (r, c),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final h in hits.take(limit)) h.$2];
}

/// The listed city nearest to a place, when one is within [withinKm].
City? nearestCity(double latitude, double longitude, {double withinKm = 30}) {
  City? best;
  var bestKm = withinKm;
  for (final c in cities) {
    final km = c.kmTo(latitude, longitude);
    if (km <= bestKm) {
      best = c;
      bestKm = km;
    }
  }
  return best;
}

/// The cities offered offline: India's larger cities, then the world's
/// capitals and a few large cities people look for.
const cities = <City>[
  // India.
  City('Bengaluru', 'India', 12.9716, 77.5946, ['Bangalore']),
  City('Mumbai', 'India', 19.0760, 72.8777, ['Bombay']),
  City('New Delhi', 'India', 28.6139, 77.2090, ['Delhi']),
  City('Kolkata', 'India', 22.5726, 88.3639, ['Calcutta']),
  City('Chennai', 'India', 13.0827, 80.2707, ['Madras']),
  City('Hyderabad', 'India', 17.3850, 78.4867),
  City('Pune', 'India', 18.5204, 73.8567, ['Poona']),
  City('Ahmedabad', 'India', 23.0225, 72.5714),
  City('Surat', 'India', 21.1702, 72.8311),
  City('Jaipur', 'India', 26.9124, 75.7873),
  City('Lucknow', 'India', 26.8467, 80.9462),
  City('Kanpur', 'India', 26.4499, 80.3319),
  City('Nagpur', 'India', 21.1458, 79.0882),
  City('Indore', 'India', 22.7196, 75.8577),
  City('Bhopal', 'India', 23.2599, 77.4126),
  City('Thane', 'India', 19.2183, 72.9781),
  City('Navi Mumbai', 'India', 19.0330, 73.0297),
  City('Visakhapatnam', 'India', 17.6868, 83.2185, ['Vizag']),
  City('Vijayawada', 'India', 16.5062, 80.6480),
  City('Patna', 'India', 25.5941, 85.1376),
  City('Vadodara', 'India', 22.3072, 73.1812, ['Baroda']),
  City('Ludhiana', 'India', 30.9010, 75.8573),
  City('Agra', 'India', 27.1767, 78.0081),
  City('Nashik', 'India', 19.9975, 73.7898),
  City('Rajkot', 'India', 22.3039, 70.8022),
  City('Varanasi', 'India', 25.3176, 82.9739, ['Banaras', 'Benares']),
  City('Srinagar', 'India', 34.0837, 74.7973),
  City('Amritsar', 'India', 31.6340, 74.8723),
  City('Chandigarh', 'India', 30.7333, 76.7794),
  City('Gurugram', 'India', 28.4595, 77.0266, ['Gurgaon']),
  City('Noida', 'India', 28.5355, 77.3910),
  City('Ghaziabad', 'India', 28.6692, 77.4538),
  City('Faridabad', 'India', 28.4089, 77.3178),
  City('Coimbatore', 'India', 11.0168, 76.9558),
  City('Madurai', 'India', 9.9252, 78.1198),
  City('Tiruchirappalli', 'India', 10.7905, 78.7047, ['Trichy']),
  City('Mysuru', 'India', 12.2958, 76.6394, ['Mysore']),
  City('Mangaluru', 'India', 12.9141, 74.8560, ['Mangalore']),
  City('Hubballi', 'India', 15.3647, 75.1240, ['Hubli']),
  City('Kochi', 'India', 9.9312, 76.2673, ['Cochin']),
  City('Thiruvananthapuram', 'India', 8.5241, 76.9366, ['Trivandrum']),
  City('Kozhikode', 'India', 11.2588, 75.7804, ['Calicut']),
  City('Guwahati', 'India', 26.1445, 91.7362),
  City('Bhubaneswar', 'India', 20.2961, 85.8245),
  City('Ranchi', 'India', 23.3441, 85.3096),
  City('Raipur', 'India', 21.2514, 81.6296),
  City('Dehradun', 'India', 30.3165, 78.0322),
  City('Shimla', 'India', 31.1048, 77.1734),
  City('Jammu', 'India', 32.7266, 74.8570),
  City('Jodhpur', 'India', 26.2389, 73.0243),
  City('Udaipur', 'India', 24.5854, 73.7125),
  City('Gwalior', 'India', 26.2183, 78.1828),
  City('Jabalpur', 'India', 23.1815, 79.9864),
  City('Aurangabad', 'India', 19.8762, 75.3433, ['Chhatrapati Sambhajinagar']),
  City('Kolhapur', 'India', 16.7050, 74.2433),
  City('Panaji', 'India', 15.4909, 73.8278, ['Goa', 'Panjim']),
  City('Puducherry', 'India', 11.9416, 79.8083, ['Pondicherry']),
  City('Prayagraj', 'India', 25.4358, 81.8463, ['Allahabad']),
  City('Meerut', 'India', 28.9845, 77.7064),
  City('Siliguri', 'India', 26.7271, 88.3953),
  City('Imphal', 'India', 24.8170, 93.9368),
  City('Shillong', 'India', 25.5788, 91.8933),
  City('Gangtok', 'India', 27.3389, 88.6065),
  City('Agartala', 'India', 23.8315, 91.2868),
  City('Aizawl', 'India', 23.7271, 92.7176),
  City('Kohima', 'India', 25.6751, 94.1086),
  City('Itanagar', 'India', 27.0844, 93.6053),
  City('Gandhinagar', 'India', 23.2156, 72.6369),
  City('Amaravati', 'India', 16.5131, 80.5165),
  City('Warangal', 'India', 17.9689, 79.5941),
  City('Tirupati', 'India', 13.6288, 79.4192),
  City('Belagavi', 'India', 15.8497, 74.4977, ['Belgaum']),
  City('Salem', 'India', 11.6643, 78.1460),
  City('Port Blair', 'India', 11.6234, 92.7265, ['Sri Vijaya Puram']),
  City('Leh', 'India', 34.1526, 77.5771),

  // Capitals, A to Z by country.
  City('Kabul', 'Afghanistan', 34.5553, 69.2075),
  City('Tirana', 'Albania', 41.3275, 19.8187),
  City('Algiers', 'Algeria', 36.7538, 3.0588),
  City('Andorra la Vella', 'Andorra', 42.5063, 1.5218),
  City('Luanda', 'Angola', -8.8390, 13.2894),
  City("St. John's", 'Antigua and Barbuda', 17.1274, -61.8468),
  City('Buenos Aires', 'Argentina', -34.6037, -58.3816),
  City('Yerevan', 'Armenia', 40.1792, 44.4991),
  City('Canberra', 'Australia', -35.2809, 149.1300),
  City('Vienna', 'Austria', 48.2082, 16.3738, ['Wien']),
  City('Baku', 'Azerbaijan', 40.4093, 49.8671),
  City('Nassau', 'Bahamas', 25.0443, -77.3504),
  City('Manama', 'Bahrain', 26.2285, 50.5860),
  City('Dhaka', 'Bangladesh', 23.8103, 90.4125),
  City('Bridgetown', 'Barbados', 13.0969, -59.6145),
  City('Minsk', 'Belarus', 53.9006, 27.5590),
  City('Brussels', 'Belgium', 50.8503, 4.3517),
  City('Belmopan', 'Belize', 17.2510, -88.7590),
  City('Porto-Novo', 'Benin', 6.4969, 2.6289),
  City('Thimphu', 'Bhutan', 27.4728, 89.6390),
  City('Sucre', 'Bolivia', -19.0196, -65.2619),
  City('La Paz', 'Bolivia', -16.4897, -68.1193),
  City('Sarajevo', 'Bosnia and Herzegovina', 43.8563, 18.4131),
  City('Gaborone', 'Botswana', -24.6282, 25.9231),
  City('Brasília', 'Brazil', -15.7939, -47.8828, ['Brasilia']),
  City('Bandar Seri Begawan', 'Brunei', 4.9031, 114.9398),
  City('Sofia', 'Bulgaria', 42.6977, 23.3219),
  City('Ouagadougou', 'Burkina Faso', 12.3714, -1.5197),
  City('Gitega', 'Burundi', -3.4271, 29.9246),
  City('Praia', 'Cabo Verde', 14.9330, -23.5133, ['Cape Verde']),
  City('Phnom Penh', 'Cambodia', 11.5564, 104.9282),
  City('Yaoundé', 'Cameroon', 3.8480, 11.5021, ['Yaounde']),
  City('Ottawa', 'Canada', 45.4215, -75.6972),
  City('Bangui', 'Central African Republic', 4.3947, 18.5582),
  City("N'Djamena", 'Chad', 12.1348, 15.0557, ['Ndjamena']),
  City('Santiago', 'Chile', -33.4489, -70.6693),
  City('Beijing', 'China', 39.9042, 116.4074, ['Peking']),
  City('Bogotá', 'Colombia', 4.7110, -74.0721, ['Bogota']),
  City('Moroni', 'Comoros', -11.7172, 43.2473),
  City('Kinshasa', 'DR Congo', -4.4419, 15.2663),
  City('Brazzaville', 'Congo', -4.2634, 15.2429),
  City('San José', 'Costa Rica', 9.9281, -84.0907, ['San Jose']),
  City('Yamoussoukro', "Côte d'Ivoire", 6.8276, -5.2893, ['Ivory Coast']),
  City('Zagreb', 'Croatia', 45.8150, 15.9819),
  City('Havana', 'Cuba', 23.1136, -82.3666),
  City('Nicosia', 'Cyprus', 35.1856, 33.3823),
  City('Prague', 'Czechia', 50.0755, 14.4378, ['Praha', 'Czech Republic']),
  City('Copenhagen', 'Denmark', 55.6761, 12.5683),
  City('Djibouti', 'Djibouti', 11.5721, 43.1456),
  City('Roseau', 'Dominica', 15.3092, -61.3794),
  City('Santo Domingo', 'Dominican Republic', 18.4861, -69.9312),
  City('Dili', 'East Timor', -8.5569, 125.5603, ['Timor-Leste']),
  City('Quito', 'Ecuador', -0.1807, -78.4678),
  City('Cairo', 'Egypt', 30.0444, 31.2357),
  City('San Salvador', 'El Salvador', 13.6929, -89.2182),
  City('Malabo', 'Equatorial Guinea', 3.7504, 8.7371),
  City('Asmara', 'Eritrea', 15.3229, 38.9251),
  City('Tallinn', 'Estonia', 59.4370, 24.7536),
  City('Mbabane', 'Eswatini', -26.3054, 31.1367, ['Swaziland']),
  City('Addis Ababa', 'Ethiopia', 9.0300, 38.7400),
  City('Suva', 'Fiji', -18.1248, 178.4501),
  City('Helsinki', 'Finland', 60.1699, 24.9384),
  City('Paris', 'France', 48.8566, 2.3522),
  City('Libreville', 'Gabon', 0.4162, 9.4673),
  City('Banjul', 'Gambia', 13.4549, -16.5790),
  City('Tbilisi', 'Georgia', 41.7151, 44.8271),
  City('Berlin', 'Germany', 52.5200, 13.4050),
  City('Accra', 'Ghana', 5.6037, -0.1870),
  City('Athens', 'Greece', 37.9838, 23.7275),
  City("St. George's", 'Grenada', 12.0561, -61.7488),
  City('Guatemala City', 'Guatemala', 14.6349, -90.5069),
  City('Conakry', 'Guinea', 9.6412, -13.5784),
  City('Bissau', 'Guinea-Bissau', 11.8817, -15.6178),
  City('Georgetown', 'Guyana', 6.8013, -58.1551),
  City('Port-au-Prince', 'Haiti', 18.5944, -72.3074),
  City('Tegucigalpa', 'Honduras', 14.0723, -87.1921),
  City('Budapest', 'Hungary', 47.4979, 19.0402),
  City('Reykjavík', 'Iceland', 64.1466, -21.9426, ['Reykjavik']),
  City('Jakarta', 'Indonesia', -6.2088, 106.8456),
  City('Tehran', 'Iran', 35.6892, 51.3890),
  City('Baghdad', 'Iraq', 33.3152, 44.3661),
  City('Dublin', 'Ireland', 53.3498, -6.2603),
  City('Jerusalem', 'Israel', 31.7683, 35.2137),
  City('Rome', 'Italy', 41.9028, 12.4964, ['Roma']),
  City('Kingston', 'Jamaica', 17.9712, -76.7936),
  City('Tokyo', 'Japan', 35.6762, 139.6503),
  City('Amman', 'Jordan', 31.9539, 35.9106),
  City('Astana', 'Kazakhstan', 51.1694, 71.4491),
  City('Nairobi', 'Kenya', -1.2921, 36.8219),
  City('Tarawa', 'Kiribati', 1.4518, 172.9717),
  City('Pristina', 'Kosovo', 42.6629, 21.1655),
  City('Kuwait City', 'Kuwait', 29.3759, 47.9774),
  City('Bishkek', 'Kyrgyzstan', 42.8746, 74.5698),
  City('Vientiane', 'Laos', 17.9757, 102.6331),
  City('Riga', 'Latvia', 56.9496, 24.1052),
  City('Beirut', 'Lebanon', 33.8938, 35.5018),
  City('Maseru', 'Lesotho', -29.3151, 27.4869),
  City('Monrovia', 'Liberia', 6.3156, -10.8074),
  City('Tripoli', 'Libya', 32.8872, 13.1913),
  City('Vaduz', 'Liechtenstein', 47.1410, 9.5209),
  City('Vilnius', 'Lithuania', 54.6872, 25.2797),
  City('Luxembourg', 'Luxembourg', 49.6116, 6.1319),
  City('Antananarivo', 'Madagascar', -18.8792, 47.5079),
  City('Lilongwe', 'Malawi', -13.9626, 33.7741),
  City('Kuala Lumpur', 'Malaysia', 3.1390, 101.6869),
  City('Malé', 'Maldives', 4.1755, 73.5093, ['Male']),
  City('Bamako', 'Mali', 12.6392, -8.0029),
  City('Valletta', 'Malta', 35.8989, 14.5146),
  City('Majuro', 'Marshall Islands', 7.1164, 171.1858),
  City('Nouakchott', 'Mauritania', 18.0735, -15.9582),
  City('Port Louis', 'Mauritius', -20.1609, 57.5012),
  City('Mexico City', 'Mexico', 19.4326, -99.1332),
  City('Palikir', 'Micronesia', 6.9248, 158.1610),
  City('Chișinău', 'Moldova', 47.0105, 28.8638, ['Chisinau']),
  City('Monaco', 'Monaco', 43.7384, 7.4246),
  City('Ulaanbaatar', 'Mongolia', 47.8864, 106.9057),
  City('Podgorica', 'Montenegro', 42.4304, 19.2594),
  City('Rabat', 'Morocco', 34.0209, -6.8416),
  City('Maputo', 'Mozambique', -25.9692, 32.5732),
  City('Naypyidaw', 'Myanmar', 19.7633, 96.0785),
  City('Yangon', 'Myanmar', 16.8409, 96.1735, ['Rangoon']),
  City('Windhoek', 'Namibia', -22.5609, 17.0658),
  City('Yaren', 'Nauru', -0.5477, 166.9209),
  City('Kathmandu', 'Nepal', 27.7172, 85.3240),
  City('Amsterdam', 'Netherlands', 52.3676, 4.9041),
  City('Wellington', 'New Zealand', -41.2865, 174.7762),
  City('Managua', 'Nicaragua', 12.1150, -86.2362),
  City('Niamey', 'Niger', 13.5116, 2.1254),
  City('Abuja', 'Nigeria', 9.0765, 7.3986),
  City('Pyongyang', 'North Korea', 39.0392, 125.7625),
  City('Skopje', 'North Macedonia', 41.9981, 21.4254),
  City('Oslo', 'Norway', 59.9139, 10.7522),
  City('Muscat', 'Oman', 23.5880, 58.3829),
  City('Islamabad', 'Pakistan', 33.6844, 73.0479),
  City('Ngerulmud', 'Palau', 7.5006, 134.6242),
  City('Ramallah', 'Palestine', 31.9038, 35.2034),
  City('Panama City', 'Panama', 8.9824, -79.5199),
  City('Port Moresby', 'Papua New Guinea', -9.4438, 147.1803),
  City('Asunción', 'Paraguay', -25.2637, -57.5759, ['Asuncion']),
  City('Lima', 'Peru', -12.0464, -77.0428),
  City('Manila', 'Philippines', 14.5995, 120.9842),
  City('Warsaw', 'Poland', 52.2297, 21.0122, ['Warszawa']),
  City('Lisbon', 'Portugal', 38.7223, -9.1393, ['Lisboa']),
  City('Doha', 'Qatar', 25.2854, 51.5310),
  City('Bucharest', 'Romania', 44.4268, 26.1025),
  City('Moscow', 'Russia', 55.7558, 37.6173),
  City('Kigali', 'Rwanda', -1.9441, 30.0619),
  City('Basseterre', 'Saint Kitts and Nevis', 17.3026, -62.7177),
  City('Castries', 'Saint Lucia', 14.0101, -60.9875),
  City('Kingstown', 'Saint Vincent and the Grenadines', 13.1600, -61.2248),
  City('Apia', 'Samoa', -13.8507, -171.7514),
  City('San Marino', 'San Marino', 43.9424, 12.4578),
  City('São Tomé', 'São Tomé and Príncipe', 0.3365, 6.7273, ['Sao Tome']),
  City('Riyadh', 'Saudi Arabia', 24.7136, 46.6753),
  City('Dakar', 'Senegal', 14.7167, -17.4677),
  City('Belgrade', 'Serbia', 44.7866, 20.4489),
  City('Victoria', 'Seychelles', -4.6191, 55.4513),
  City('Freetown', 'Sierra Leone', 8.4657, -13.2317),
  City('Singapore', 'Singapore', 1.3521, 103.8198),
  City('Bratislava', 'Slovakia', 48.1486, 17.1077),
  City('Ljubljana', 'Slovenia', 46.0569, 14.5058),
  City('Honiara', 'Solomon Islands', -9.4456, 159.9729),
  City('Mogadishu', 'Somalia', 2.0469, 45.3182),
  City('Pretoria', 'South Africa', -25.7479, 28.2293),
  City('Cape Town', 'South Africa', -33.9249, 18.4241),
  City('Seoul', 'South Korea', 37.5665, 126.9780),
  City('Juba', 'South Sudan', 4.8594, 31.5713),
  City('Madrid', 'Spain', 40.4168, -3.7038),
  City('Colombo', 'Sri Lanka', 6.9271, 79.8612),
  City('Sri Jayawardenepura Kotte', 'Sri Lanka', 6.8868, 79.9187, ['Kotte']),
  City('Khartoum', 'Sudan', 15.5007, 32.5599),
  City('Paramaribo', 'Suriname', 5.8520, -55.2038),
  City('Stockholm', 'Sweden', 59.3293, 18.0686),
  City('Bern', 'Switzerland', 46.9480, 7.4474, ['Berne']),
  City('Damascus', 'Syria', 33.5138, 36.2765),
  City('Taipei', 'Taiwan', 25.0330, 121.5654),
  City('Dushanbe', 'Tajikistan', 38.5598, 68.7870),
  City('Dodoma', 'Tanzania', -6.1630, 35.7516),
  City('Bangkok', 'Thailand', 13.7563, 100.5018),
  City('Lomé', 'Togo', 6.1256, 1.2254, ['Lome']),
  City("Nuku'alofa", 'Tonga', -21.1394, -175.2018),
  City('Port of Spain', 'Trinidad and Tobago', 10.6549, -61.5019),
  City('Tunis', 'Tunisia', 36.8065, 10.1815),
  City('Ankara', 'Türkiye', 39.9334, 32.8597, ['Turkey']),
  City('Ashgabat', 'Turkmenistan', 37.9601, 58.3261),
  City('Funafuti', 'Tuvalu', -8.5211, 179.1983),
  City('Kampala', 'Uganda', 0.3476, 32.5825),
  City('Kyiv', 'Ukraine', 50.4501, 30.5234, ['Kiev']),
  City('Abu Dhabi', 'United Arab Emirates', 24.4539, 54.3773, ['UAE']),
  City('London', 'United Kingdom', 51.5074, -0.1278, ['UK', 'England']),
  City('Washington, D.C.', 'United States', 38.9072, -77.0369, [
    'Washington',
    'USA',
  ]),
  City('Montevideo', 'Uruguay', -34.9011, -56.1645),
  City('Tashkent', 'Uzbekistan', 41.2995, 69.2401),
  City('Port Vila', 'Vanuatu', -17.7333, 168.3273),
  City('Vatican City', 'Vatican City', 41.9029, 12.4534),
  City('Caracas', 'Venezuela', 10.4806, -66.9036),
  City('Hanoi', 'Vietnam', 21.0278, 105.8342),
  City("Sana'a", 'Yemen', 15.3694, 44.1910, ['Sanaa']),
  City('Lusaka', 'Zambia', -15.3875, 28.3228),
  City('Harare', 'Zimbabwe', -17.8252, 31.0335),

  // Large cities that are not capitals.
  City('Dubai', 'United Arab Emirates', 25.2048, 55.2708),
  City('Karachi', 'Pakistan', 24.8607, 67.0011),
  City('Lahore', 'Pakistan', 31.5204, 74.3587),
  City('Chittagong', 'Bangladesh', 22.3569, 91.7832, ['Chattogram']),
  City('Shanghai', 'China', 31.2304, 121.4737),
  City('Hong Kong', 'China', 22.3193, 114.1694),
  City('Shenzhen', 'China', 22.5431, 114.0579),
  City('Osaka', 'Japan', 34.6937, 135.5023),
  City('Ho Chi Minh City', 'Vietnam', 10.8231, 106.6297, ['Saigon']),
  City('Sydney', 'Australia', -33.8688, 151.2093),
  City('Melbourne', 'Australia', -37.8136, 144.9631),
  City('Auckland', 'New Zealand', -36.8509, 174.7645),
  City('Istanbul', 'Türkiye', 41.0082, 28.9784, ['Turkey']),
  City('Jeddah', 'Saudi Arabia', 21.4858, 39.1925),
  City('Lagos', 'Nigeria', 6.5244, 3.3792),
  City('Johannesburg', 'South Africa', -26.2041, 28.0473),
  City('Casablanca', 'Morocco', 33.5731, -7.5898),
  City('Toronto', 'Canada', 43.6532, -79.3832),
  City('Vancouver', 'Canada', 49.2827, -123.1207),
  City('Montreal', 'Canada', 45.5017, -73.5673),
  City('New York', 'United States', 40.7128, -74.0060, ['NYC']),
  City('Los Angeles', 'United States', 34.0522, -118.2437),
  City('San Francisco', 'United States', 37.7749, -122.4194),
  City('Seattle', 'United States', 47.6062, -122.3321),
  City('Chicago', 'United States', 41.8781, -87.6298),
  City('Houston', 'United States', 29.7604, -95.3698),
  City('Dallas', 'United States', 32.7767, -96.7970),
  City('Austin', 'United States', 30.2672, -97.7431),
  City('Boston', 'United States', 42.3601, -71.0589),
  City('Miami', 'United States', 25.7617, -80.1918),
  City('Atlanta', 'United States', 33.7490, -84.3880),
  City('São Paulo', 'Brazil', -23.5505, -46.6333, ['Sao Paulo']),
  City('Rio de Janeiro', 'Brazil', -22.9068, -43.1729),
  City('Manchester', 'United Kingdom', 53.4808, -2.2426),
  City('Edinburgh', 'United Kingdom', 55.9533, -3.1883),
  City('Barcelona', 'Spain', 41.3874, 2.1686),
  City('Milan', 'Italy', 45.4642, 9.1900, ['Milano']),
  City('Munich', 'Germany', 48.1351, 11.5820, ['München']),
  City('Frankfurt', 'Germany', 50.1109, 8.6821),
  City('Zürich', 'Switzerland', 47.3769, 8.5417, ['Zurich']),
  City('Geneva', 'Switzerland', 46.2044, 6.1432),
  City('Saint Petersburg', 'Russia', 59.9311, 30.3609),
];
