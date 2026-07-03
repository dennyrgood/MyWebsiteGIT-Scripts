// shared-data.js - ES5 compatible for all devices
// Handles all API calls and data fetching logic

var SharedData = (function() {
    'use strict';
    
    // Configuration
    var CONFIG = {
        PROXY_URL: 'https://weatherproxy.ldmathes.cc/',
        //PROXY_URL: 'http://192.168.178.27:5005/',
        USE_PROXY: false // Set to true for iPad2, false for modern devices
    };
    
    function setProxyMode(useProxy, proxyUrl) {
        CONFIG.USE_PROXY = useProxy;
        if (proxyUrl) CONFIG.PROXY_URL = proxyUrl;
    }
    
    function padZero(num) {
        return num < 10 ? '0' + num : '' + num;
    }
    
    function getWeatherIcon(code) {
        if (code === 0) return '☀️';
        else if (code <= 3) return '☁️';
        else if (code <= 67) return '🌧️';
        else if (code <= 77) return '❄️';
        else if (code <= 99) return '⛈️';
        return '☀️';
    }
    
    function getDayName(dateStr) {
        var date = new Date(dateStr);
        var days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
        return days[date.getDay()];
    }
    
    function isInActiveWindow() {
        var now = new Date();
        var utcDay = now.getUTCDay();
        var utcHour = now.getUTCHours();
        
        // Block midnight to 7 AM UTC
        if (utcHour >= 0 && utcHour <= 7) return false;
        
        // Weekend block-out
        if (utcDay === 5 && utcHour >= 21) return false;
        if (utcDay === 6) return false;
        if (utcDay === 0 && utcHour < 21) return false;
        
        return true;
    }
    
    function fetchWeather(lat, lon, callback) {
        var apiUrl = 'https://api.open-meteo.com/v1/forecast?latitude=' + lat + '&longitude=' + lon + 
                     '&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m' +
                     '&daily=sunrise,sunset,temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code' +
                     '&temperature_unit=celsius&wind_speed_unit=mph&timezone=auto&forecast_days=4';
        
        var url = CONFIG.USE_PROXY ? CONFIG.PROXY_URL + '?url=' + encodeURIComponent(apiUrl) : apiUrl;
        
        var xhr = new XMLHttpRequest();
        xhr.open('GET', url, true);
        xhr.timeout = 20000;
        
        xhr.onload = function() {
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    
                    if (data.error || data.reason) {
                        callback({
                            error: data.reason || (typeof data.error === 'string' ? data.error : 'Unknown error')
                        });
                        return;
                    }
                    
                    var processed = {
                        current: {
                            tempC: Math.round(data.current.temperature_2m),
                            tempF: Math.round(data.current.temperature_2m * 9/5 + 32),
                            feelsLikeC: Math.round(data.current.apparent_temperature),
                            feelsLikeF: Math.round(data.current.apparent_temperature * 9/5 + 32),
                            humidity: data.current.relative_humidity_2m,
                            windSpeed: Math.round(data.current.wind_speed_10m),
                            weatherCode: data.current.weather_code,
                            icon: getWeatherIcon(data.current.weather_code)
                        },
                        today: {
                            highC: Math.round(data.daily.temperature_2m_max[0]),
                            highF: Math.round(data.daily.temperature_2m_max[0] * 9/5 + 32),
                            lowC: Math.round(data.daily.temperature_2m_min[0]),
                            lowF: Math.round(data.daily.temperature_2m_min[0] * 9/5 + 32),
                            rainChance: data.daily.precipitation_probability_max[0] || 0,
                            sunrise: new Date(data.daily.sunrise[0]),
                            sunset: new Date(data.daily.sunset[0])
                        },
                        forecast: []
                    };
                    
                    for (var i = 1; i <= 3; i++) {
                        processed.forecast.push({
                            day: getDayName(data.daily.time[i]),
                            highC: Math.round(data.daily.temperature_2m_max[i]),
                            highF: Math.round(data.daily.temperature_2m_max[i] * 9/5 + 32),
                            lowC: Math.round(data.daily.temperature_2m_min[i]),
                            lowF: Math.round(data.daily.temperature_2m_min[i] * 9/5 + 32),
                            icon: getWeatherIcon(data.daily.weather_code[i]),
                            rainChance: data.daily.precipitation_probability_max[i] || 0
                        });
                    }
                    
                    callback(null, processed);
                    
                } catch (e) {
                    callback({ error: 'Parse error: ' + e.message });
                }
            } else {
                callback({ error: 'HTTP Error ' + xhr.status });
            }
        };
        
        xhr.onerror = function() {
            callback({ error: 'Network error' });
        };
        
        xhr.ontimeout = function() {
            callback({ error: 'Request timeout' });
        };
        
        xhr.send();
    }
    
    function fetchCurrency(thresholds, callback) {
        var lowThreshold = thresholds.low || 1.1;
        var highThreshold = thresholds.high || 1.2;
        
        var results = {
            oxr: null,
            ecb: null,
            alt: null
        };
        var completed = 0;
        
        function checkComplete() {
            completed++;
            if (completed >= 3) {
                var displayRate = results.oxr ? results.oxr.rate : 
                                 results.ecb ? results.ecb.rate : 
                                 results.alt ? results.alt.rate : '0.00000';
                
                var source = results.oxr ? 'OXR' : results.ecb ? 'ECB' : results.alt ? 'Alt' : '';
                var rateNum = parseFloat(displayRate);
                
                var status = '';
                if (rateNum < lowThreshold) status = 'low';
                else if (rateNum > highThreshold) status = 'high';
                
                callback(null, {
                    rate: displayRate,
                    source: source,
                    status: status,
                    details: results
                });
            }
        }
        
        // OXR
        var xhr1 = new XMLHttpRequest();
        var apiUrl1 = 'https://openexchangerates.org/api/latest.json?app_id=59f0442d524d41608055554519509c57';
        var url1 = CONFIG.USE_PROXY ? CONFIG.PROXY_URL + '?url=' + encodeURIComponent(apiUrl1) : apiUrl1;
        xhr1.open('GET', url1, true);
        xhr1.onload = function() {
            if (xhr1.status === 200) {
                try {
                    var data = JSON.parse(xhr1.responseText);
                    var usdEurRate = data.rates.EUR;
                    var rate = (1 / usdEurRate).toFixed(5);
                    
                    var updateDate = new Date(data.timestamp * 1000);
                    var months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
                    var dateTime = months[updateDate.getMonth()] + ' ' + updateDate.getDate() + 
                                  ', ' + padZero(updateDate.getHours()) + ':' + padZero(updateDate.getMinutes());
                    
                    results.oxr = { rate: rate, dateTime: dateTime };
                } catch (e) {}
            }
            checkComplete();
        };
        xhr1.onerror = function() { checkComplete(); };
        xhr1.send();
        
        // ECB
        var xhr2 = new XMLHttpRequest();
        var apiUrl2 = 'https://api.frankfurter.app/latest?from=EUR&to=USD';
        var url2 = CONFIG.USE_PROXY ? CONFIG.PROXY_URL + '?url=' + encodeURIComponent(apiUrl2) : apiUrl2;
        xhr2.open('GET', url2, true);
        xhr2.onload = function() {
            if (xhr2.status === 200) {
                try {
                    var data = JSON.parse(xhr2.responseText);
                    results.ecb = { rate: data.rates.USD.toFixed(5), date: data.date };
                } catch (e) {}
            }
            checkComplete();
        };
        xhr2.onerror = function() { checkComplete(); };
        xhr2.send();
        
        // Alt
        var xhr3 = new XMLHttpRequest();
        var apiUrl3 = 'https://api.exchangerate-api.com/v4/latest/EUR';
        var url3 = CONFIG.USE_PROXY ? CONFIG.PROXY_URL + '?url=' + encodeURIComponent(apiUrl3) : apiUrl3;
        xhr3.open('GET', url3, true);
        xhr3.onload = function() {
            if (xhr3.status === 200) {
                try {
                    var data = JSON.parse(xhr3.responseText);
                    var rate = data.rates.USD.toFixed(5);
                    var dateTime = null;
                    
                    if (data.time_last_update_utc) {
                        var updateDate = new Date(data.time_last_update_utc);
                        if (!isNaN(updateDate.getTime())) {
                            var months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
                            dateTime = months[updateDate.getMonth()] + ' ' + updateDate.getDate() + 
                                      ', ' + padZero(updateDate.getHours()) + ':' + padZero(updateDate.getMinutes());
                        }
                    }
                    
                    results.alt = { rate: rate, dateTime: dateTime };
                } catch (e) {}
            }
            checkComplete();
        };
        xhr3.onerror = function() { checkComplete(); };
        xhr3.send();
    }
    
    return {
        setProxyMode: setProxyMode,
        fetchWeather: fetchWeather,
        fetchCurrency: fetchCurrency,
        isInActiveWindow: isInActiveWindow,
        padZero: padZero
    };
})();
