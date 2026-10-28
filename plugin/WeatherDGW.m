/*
 * WeatherDGW - makes iOS 3 Weather.app work again, worldwide.
 *
 * Two request types are served locally over plain HTTP:
 *   type="getlocationid"           city search   -> geocoding-api.open-meteo.com
 *   type="getforecastbylocationid" weather       -> api.open-meteo.com
 *
 * Weather replies use XML *attributes* (the app reads them with xmlHasProp):
 *   <location id=".." city=".." zip=".."/>  <units temperature="F"/>
 *   <astronomy .../> <condition .../> <forecast .../> x6  <link>..</link>
 *
 * Search replies use child element text (the app reads those with
 * xmlNodeGetContent): <item><id>..</id><city>..</city><region>..</region>
 * <country>..</country></item>
 *
 * City ids are self-describing:  OM|lat|lon|Display Name
 * so any location on earth works without a lookup table.  Old
 * CHXX....|woeid ids still resolve through the built-in table.
 */
#import <Foundation/Foundation.h>

typedef struct {
    double lat;
    double lon;
    char name[96];
    char region[96];
    char country[64];
} GeoItem;

static int yahoo_code(int wmo, int isDay) {
    switch (wmo) {
        case 0:  return isDay ? 32 : 31;
        case 1:  return isDay ? 34 : 33;
        case 2:  return isDay ? 30 : 29;
        case 3:  return isDay ? 28 : 27;
        case 45: case 48: return 20;
        case 51: case 53: case 55: return 9;
        case 56: case 57: return 8;
        case 61: return 11;
        case 63: return 12;
        case 65: return 40;
        case 66: case 67: return 10;
        case 71: return 14;
        case 73: return 16;
        case 75: return 42;
        case 77: return 13;
        case 80: case 81: return 39;
        case 82: return 40;
        case 85: case 86: return 41;
        case 95: return 4;
        case 96: case 99: return 3;
    }
    return 44;
}

static const char *yahoo_text(int wmo) {
    switch (wmo) {
        case 0:  return "Sunny";
        case 1:  return "Fair";
        case 2:  return "Partly Cloudy";
        case 3:  return "Cloudy";
        case 45: case 48: return "Fog";
        case 51: case 53: case 55: return "Drizzle";
        case 56: case 57: return "Freezing Drizzle";
        case 61: return "Light Rain";
        case 63: return "Rain";
        case 65: return "Heavy Rain";
        case 66: case 67: return "Freezing Rain";
        case 71: return "Light Snow";
        case 73: return "Snow";
        case 75: return "Heavy Snow";
        case 77: return "Snow Grains";
        case 80: case 81: return "Showers";
        case 82: return "Heavy Showers";
        case 85: case 86: return "Snow Showers";
        case 95: return "Thunderstorm";
        case 96: case 99: return "Thunderstorm";
    }
    return "Clear";
}

/* ---- tiny JSON helpers (iOS 3 has no NSJSONSerialization) ---- */

static const char *json_section(const char *json, const char *key) {
    char pat[64];
    const char *p;
    snprintf(pat, sizeof(pat), "\"%s\":{", key);
    p = strstr(json, pat);
    return p ? p + strlen(pat) : NULL;
}

static double json_double(const char *p, const char *key) {
    char pat[64];
    const char *q;
    if (!p) return 0;
    snprintf(pat, sizeof(pat), "\"%s\":", key);
    q = strstr(p, pat);
    return q ? atof(q + strlen(pat)) : 0;
}

static int json_numbers(const char *p, const char *key, double *out, int max) {
    char pat[64];
    const char *q;
    int n = 0;
    if (!p) return 0;
    snprintf(pat, sizeof(pat), "\"%s\":[", key);
    q = strstr(p, pat);
    if (!q) return 0;
    q += strlen(pat);
    while (*q && *q != ']' && n < max) {
        while (*q == ' ' || *q == ',') q++;
        if (*q == ']' || !*q) break;
        out[n++] = atof(q);
        while (*q && *q != ',' && *q != ']') q++;
    }
    return n;
}

static int json_strings(const char *p, const char *key, char out[][24], int max) {
    char pat[64];
    const char *q;
    int n = 0;
    if (!p) return 0;
    snprintf(pat, sizeof(pat), "\"%s\":[", key);
    q = strstr(p, pat);
    if (!q) return 0;
    q += strlen(pat);
    while (*q && *q != ']' && n < max) {
        const char *a;
        int len;
        while (*q && *q != '"') q++;
        if (!*q) break;
        a = ++q;
        while (*q && *q != '"') q++;
        len = (int)(q - a);
        if (len > 23) len = 23;
        memcpy(out[n], a, len);
        out[n][len] = 0;
        n++;
        if (*q) q++;
    }
    return n;
}

static const char *key_in(const char *s, const char *end, const char *key) {
    char pat[64];
    const char *q;
    snprintf(pat, sizeof(pat), "\"%s\":", key);
    q = strstr(s, pat);
    return (q && q < end) ? q : NULL;
}

static void str_in(const char *s, const char *end, const char *key, char *out, int cap) {
    const char *q = key_in(s, end, key);
    int len;
    out[0] = 0;
    if (!q) return;
    q += strlen(key) + 3;
    while (*q == ' ') q++;
    if (*q != '"') return;
    q++;
    len = 0;
    while (*q && *q != '"' && len < cap - 1) out[len++] = *q++;
    out[len] = 0;
}

static double num_in(const char *s, const char *end, const char *key) {
    const char *q = key_in(s, end, key);
    return q ? atof(q + strlen(key) + 3) : 0;
}

static int parse_geo(const char *js, GeoItem *out, int max) {
    const char *p = strstr(js, "\"results\":[");
    int n = 0;
    if (!p) return 0;
    p += 11;
    while (*p && n < max) {
        const char *obj = strchr(p, '{');
        const char *end;
        if (!obj) break;
        end = strchr(obj, '}');
        if (!end) break;
        out[n].lat = num_in(obj, end, "latitude");
        out[n].lon = num_in(obj, end, "longitude");
        str_in(obj, end, "name", out[n].name, sizeof(out[n].name));
        str_in(obj, end, "admin1", out[n].region, sizeof(out[n].region));
        str_in(obj, end, "country", out[n].country, sizeof(out[n].country));
        n++;
        p = end + 1;
    }
    return n;
}

static NSString *hm12(const char *iso) {
    const char *t = strchr(iso, 'T');
    int h, m;
    if (!t || strlen(t) < 6) return @"12:00 am";
    h = (t[1] - '0') * 10 + (t[2] - '0');
    m = (t[4] - '0') * 10 + (t[5] - '0');
    return [NSString stringWithFormat:@"%d:%02d %@", h % 12 == 0 ? 12 : h % 12, m, h < 12 ? @"am" : @"pm"];
}

static int moon_index(void) {
    double ref = 947182440.0;
    double synodic = 29.530588853;
    double days = ([[NSDate date] timeIntervalSince1970] - ref) / 86400.0;
    double age = fmod(days, synodic);
    int idx;
    if (age < 0) age += synodic;
    idx = (int)(age / synodic * 24.0) + 1;
    return idx > 24 ? 24 : idx;
}

/* Old Yahoo ids that came from DefaultCities.plist carry no coordinates.
 * The app ships that plist (region -> CityID/CityName), so use the name for
 * a geocoding lookup and remember the result for this process. */
static NSDictionary *gDefaultCityNames = nil;
static NSMutableDictionary *gGeoCache = nil;

static NSDictionary *default_city_names(void) {
    NSDictionary *raw;
    NSMutableDictionary *map;
    NSEnumerator *e;
    NSString *region;
    if (gDefaultCityNames) return gDefaultCityNames;
    raw = [NSDictionary dictionaryWithContentsOfFile:
           @"/Applications/Weather.app/DefaultCities.plist"];
    map = [NSMutableDictionary dictionary];
    e = [raw keyEnumerator];
    while ((region = [e nextObject])) {
        NSArray *cities = [raw objectForKey:region];
        NSUInteger i;
        if (![cities isKindOfClass:[NSArray class]]) continue;
        for (i = 0; i < [cities count]; i++) {
            NSDictionary *c = [cities objectAtIndex:i];
            NSString *cid = [c objectForKey:@"CityID"];
            NSString *nm = [c objectForKey:@"CityName"];
            if (cid && nm) [map setObject:nm forKey:cid];
        }
    }
    gDefaultCityNames = [map retain];
    return gDefaultCityNames;
}

static NSString *esc(NSString *s) {
    NSMutableString *m;
    if (!s) return @"";
    m = [NSMutableString stringWithString:s];
    [m replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, [m length])];
    return m;
}

static NSString *trim_utf8(const char *s, int cap) {
    char buf[128];
    int i;
    snprintf(buf, sizeof(buf), "%s", s);
    for (i = 0; buf[i]; i++) {
        if (buf[i] == '|' || buf[i] == '\n' || buf[i] == '\r') buf[i] = ' ';
    }
    return [NSString stringWithUTF8String:buf];
}

/* ---- the protocol filter ---- */

@interface DGWURLProtocol : NSURLProtocol {
    BOOL _cancelled;
}
@end

@implementation DGWURLProtocol

+ (void)load {
    [NSURLProtocol registerClass:self];
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [[[request URL] path] isEqualToString:@"/dgw"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return NO;
}

- (void)startLoading {
    _cancelled = NO;
    [self retain];
    [NSThread detachNewThreadSelector:@selector(work) toTarget:self withObject:nil];
}

- (void)stopLoading {
    /* The app abandons requests all the time (typing in the city search).
     * Never touch the client after this point. */
    _cancelled = YES;
}

- (NSData *)fetchJSON:(NSString *)urlString {
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                         cachePolicy:NSURLRequestReloadIgnoringCacheData
                                     timeoutInterval:12];
    NSURLResponse *resp = nil;
    NSError *err = nil;
    return [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
}

- (NSString *)bodyString {
    NSData *d = [[self request] HTTPBody];
    if (!d) return @"";
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease];
}

static NSString *tag_text(NSString *body, NSString *tag) {
    NSRange a = [body rangeOfString:[NSString stringWithFormat:@"<%@>", tag]];
    NSRange b;
    if (a.location == NSNotFound) return nil;
    b = [body rangeOfString:[NSString stringWithFormat:@"</%@>", tag]
                    options:0
                      range:NSMakeRange(a.location, [body length] - a.location)];
    if (b.location == NSNotFound) return nil;
    return [body substringWithRange:NSMakeRange(a.location + [tag length] + 2,
                                                b.location - a.location - [tag length] - 2)];
}

- (NSData *)buildSearch:(NSString *)body {
    NSString *phrase = tag_text(body, @"phrase");
    NSString *lang = tag_text(body, @"language");
    NSString *escaped;
    NSString *json;
    NSData *data;
    GeoItem items[8];
    int n, i;
    NSMutableString *xml;

    if (!phrase || [phrase length] == 0) return nil;
    if ([lang length] >= 2) lang = [lang substringToIndex:2];
    else lang = @"en";
    escaped = [phrase stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    if (!escaped) return nil;
    data = [self fetchJSON:[NSString stringWithFormat:
        @"http://geocoding-api.open-meteo.com/v1/search?name=%@&count=8&language=%@&format=json",
        escaped, lang]];
    if (!data || [data length] == 0) return nil;
    json = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!json) return nil;
    n = parse_geo([json UTF8String], items, 8);
    if (n <= 0) return nil;

    xml = [NSMutableString stringWithCapacity:600];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
    [xml appendFormat:@"<response><result><list count=\"%d\">", n];
    for (i = 0; i < n; i++) {
        NSString *nm = trim_utf8(items[i].name, sizeof(items[i].name));
        NSString *rg = trim_utf8(items[i].region, sizeof(items[i].region));
        NSString *ct = trim_utf8(items[i].country, sizeof(items[i].country));
        NSString *ident = [NSString stringWithFormat:@"OM|%.4f|%.4f|%@",
                           items[i].lat, items[i].lon, nm];
        /* the picker appends the region only when <regionname> is present */
        [xml appendFormat:@"<item><id>%@</id><city>%@</city><region>%@</region>"
                          "<regionname>%@</regionname><country>%@</country>"
                          "<countryname>%@</countryname></item>",
                          esc(ident), esc(nm), esc(rg), esc(rg), esc(ct), esc(ct)];
    }
    [xml appendString:@"</list></result></response>"];
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

- (BOOL)geocodeName:(NSString *)name lat:(double *)outLat lon:(double *)outLon {
    /* The search index is language sensitive: "北京" needs language=zh,
     * "Beijing" is found by either, so retry with zh then en. */
    static NSString *langs[] = { @"zh", @"en" };
    NSString *escaped = [name stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    int i;
    if (!escaped) return NO;
    for (i = 0; i < 2; i++) {
        NSString *json;
        NSData *data = [self fetchJSON:[NSString stringWithFormat:
            @"http://geocoding-api.open-meteo.com/v1/search?name=%@&count=1&language=%@&format=json",
            escaped, langs[i]]];
        GeoItem item[1];
        if (!data || [data length] == 0) continue;
        json = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (!json) continue;
        if (parse_geo([json UTF8String], item, 1) <= 0) continue;
        *outLat = item[0].lat;
        *outLon = item[0].lon;
        return YES;
    }
    return NO;
}

- (NSData *)buildWeather:(NSString *)body {
    NSString *fullId = tag_text(body, @"id");
    double lat = 0, lon = 0;
    BOOL hasCoord = NO;
    NSString *cityName = nil;
    NSURL *url;
    NSURLRequest *req;
    NSURLResponse *resp = nil;
    NSError *err = nil;
    NSData *jsonData;
    NSString *json;
    const char *js, *cur, *daily;
    char days[8][24], rises[8][24], sets[8][24];
    double codes[8], highs[8], lows[8];
    int nd, i, unitF, isDay;
    double t;
    int wmo;
    NSMutableString *xml;
    NSDateFormatter *df;
    NSString *nowStr;

    if (!fullId) return nil;
    if ([fullId hasPrefix:@"OM|"]) {
        NSString *rest = [fullId substringFromIndex:3];
        NSArray *parts = [rest componentsSeparatedByString:@"|"];
        if ([parts count] >= 2) {
            lat = [[parts objectAtIndex:0] doubleValue];
            lon = [[parts objectAtIndex:1] doubleValue];
            if ([parts count] >= 3) cityName = [parts objectAtIndex:2];
            hasCoord = YES;
        }
    } else {
        /* legacy Yahoo id from the app's own DefaultCities.plist */
        NSString *nm = nil;
        NSArray *cached = nil;
        @synchronized ([DGWURLProtocol class]) {
            nm = [[default_city_names() objectForKey:fullId] retain];
            cached = [[gGeoCache objectForKey:fullId] retain];
        }
        if (cached) {
            lat = [[cached objectAtIndex:0] doubleValue];
            lon = [[cached objectAtIndex:1] doubleValue];
            cityName = nm ? nm : fullId;
            hasCoord = YES;
        } else if (nm && [self geocodeName:nm lat:&lat lon:&lon]) {
            cityName = nm;
            hasCoord = YES;
            @synchronized ([DGWURLProtocol class]) {
                if (!gGeoCache) gGeoCache = [[NSMutableDictionary alloc] init];
                [gGeoCache setObject:[NSArray arrayWithObjects:
                    [NSNumber numberWithDouble:lat],
                    [NSNumber numberWithDouble:lon], nil]
                              forKey:fullId];
            }
        }
        [nm release];
        [cached release];
    }
    if (!hasCoord) return nil;
    if (!cityName) cityName = fullId;
    unitF = [body rangeOfString:@"<unit>c</unit>"].location == NSNotFound;

    url = [NSURL URLWithString:[NSString stringWithFormat:
        @"http://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
        @"&current=temperature_2m,weather_code"
        @"&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset"
        @"&timezone=auto&forecast_days=7", lat, lon]];
    req = [NSURLRequest requestWithURL:url
                           cachePolicy:NSURLRequestReloadIgnoringCacheData
                       timeoutInterval:12];
    jsonData = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    if (!jsonData || [jsonData length] == 0) return nil;
    json = [[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] autorelease];
    if (!json) return nil;
    js = [json UTF8String];
    cur = json_section(js, "current");
    daily = json_section(js, "daily");
    if (!cur || !daily) return nil;

    nd = json_strings(daily, "time", days, 8);
    json_numbers(daily, "weather_code", codes, 8);
    json_numbers(daily, "temperature_2m_max", highs, 8);
    json_numbers(daily, "temperature_2m_min", lows, 8);
    json_strings(daily, "sunrise", rises, 8);
    json_strings(daily, "sunset", sets, 8);
    if (nd > 6) nd = 6;
    if (nd <= 0) return nil;

    t = json_double(cur, "temperature_2m");
    wmo = (int)json_double(cur, "weather_code");
    if (unitF) t = t * 9.0 / 5.0 + 32.0;

    df = [[[NSDateFormatter alloc] init] autorelease];
    [df setDateFormat:@"h:mm a"];
    nowStr = [[df stringFromDate:[NSDate date]] lowercaseString];
    {
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDateComponents *dc = [cal components:NSHourCalendarUnit fromDate:[NSDate date]];
        isDay = [dc hour] >= 6 && [dc hour] < 18;
    }

    xml = [NSMutableString stringWithCapacity:1200];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>"];
    [xml appendString:@"<response><result><list count=\"1\"><item>"];
    [xml appendFormat:@"<location id=\"%@\" city=\"%@\" zip=\"%@\"/>",
                      esc(fullId), esc(cityName), esc(fullId)];
    [xml appendFormat:@"<units temperature=\"%@\"/>", unitF ? @"F" : @"C"];
    [xml appendFormat:@"<astronomy sunrise=\"%@\" sunset=\"%@\" moonphase=\"%d\" moonfacevisible=\"0.5\"/>",
                      hm12(rises[0]), hm12(sets[0]), moon_index()];
    [xml appendFormat:@"<condition time=\"%@\" temp=\"%d\" code=\"%d\" text=\"%s\"/>",
                      nowStr, (int)(t < 0 ? t - 0.5 : t + 0.5), yahoo_code(wmo, isDay), yahoo_text(wmo)];

    for (i = 0; i < nd; i++) {
        double hi = highs[i], lo = lows[i];
        int c = (int)codes[i];
        int dow = 0;
        NSDate *d;
        NSDateFormatter *df2 = [[[NSDateFormatter alloc] init] autorelease];
        [df2 setDateFormat:@"yyyy-MM-dd"];
        d = [df2 dateFromString:[NSString stringWithUTF8String:days[i]]];
        if (d) {
            /* The app does [dayofweek intValue], clamps it to 1..7 and uses
             * index-1 into CFDateFormatter weekday symbols (0 = Sunday).
             * So 1 = Sunday ... 7 = Saturday. */
            NSDateComponents *dc = [[NSCalendar currentCalendar]
                components:NSWeekdayCalendarUnit fromDate:d];
            dow = (int)[dc weekday];
        }
        if (unitF) {
            hi = hi * 9.0 / 5.0 + 32.0;
            lo = lo * 9.0 / 5.0 + 32.0;
        }
        [xml appendFormat:@"<forecast dayofweek=\"%d\" high=\"%d\" low=\"%d\" code=\"%d\" text=\"%s\"/>",
                          dow, (int)(hi < 0 ? hi - 0.5 : hi + 0.5),
                          (int)(lo < 0 ? lo - 0.5 : lo + 0.5),
                          yahoo_code(c, 1), yahoo_text(c)];
    }
    [xml appendString:@"<link>http://weather.yahoo.com/</link>"];
    [xml appendString:@"</item></list></result></response>"];
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)buildResponse {
    NSString *body = [self bodyString];
    if ([body rangeOfString:@"type=\"getlocationid\""].location != NSNotFound) {
        return [self buildSearch:body];
    }
    return [self buildWeather:body];
}

- (void)work {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSData *xml = [self buildResponse];
    [self performSelectorOnMainThread:@selector(deliver:) withObject:xml waitUntilDone:NO];
    [pool release];
}

- (void)deliver:(NSData *)xml {
    if (!_cancelled) {
        NSURL *url = [[self request] URL];
        if (xml && url) {
            NSURLResponse *resp = [[[NSURLResponse alloc] initWithURL:url
                                                             MIMEType:@"text/xml"
                                                expectedContentLength:(NSInteger)[xml length]
                                                     textEncodingName:@"utf-8"] autorelease];
            if (resp) {
                [[self client] URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
                [[self client] URLProtocol:self didLoadData:xml];
                [[self client] URLProtocolDidFinishLoading:self];
                [self release];
                return;
            }
        }
        [[self client] URLProtocol:self didFailWithError:
            [NSError errorWithDomain:@"WeatherDGW" code:1 userInfo:nil]];
    }
    [self release];
}

@end
