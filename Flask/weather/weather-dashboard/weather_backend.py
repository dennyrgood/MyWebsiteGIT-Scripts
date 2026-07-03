import os
import requests
import json
from flask import Flask, request, jsonify, Response
from urllib.parse import urlparse, parse_qs

app = Flask(__name__)

# --- Configuration (Matches the allowed domains from your Cloudflare Worker) ---
ALLOWED_DOMAINS = [
    'api.open-meteo.com',
    'openexchangerates.org',
    'api.frankfurter.app',
    'api.exchangerate-api.com'
]

# --- Main Proxy Route ---
@app.route('/', defaults={'path': ''}, methods=['GET'])
@app.route('/<path:path>', methods=['GET'])
def proxy(path):
    """
    Acts as a proxy, fetching the URL specified in the 'url' query parameter.
    Performs security checks and conditionally injects the Open-Meteo API key.
    """
    target_url = request.args.get('url')

    if not target_url:
        return jsonify({"error": "Missing url parameter"}), 400

    try:
        parsed_target_url = urlparse(target_url)
        target_domain = parsed_target_url.hostname
    except Exception:
        return jsonify({"error": "Invalid target URL format"}), 400

    # 1. Security Check (Whitelisting)
    if target_domain not in ALLOWED_DOMAINS:
        return jsonify({"error": "Domain not allowed"}), 403

    # 2. Key Injection (Applies ONLY to Open-Meteo)
    if target_domain == 'api.open-meteo.com':
        api_key = os.environ.get('OPENMETEO_API_KEY')

        if api_key:
            # Reconstruct URL to safely set/overwrite the apikey parameter
            url_parts = list(parsed_target_url)
            query = dict(parse_qs(url_parts[4]))
            query['apikey'] = [api_key] # Open-Meteo uses 'apikey'
            url_parts[4] = requests.compat.urlencode(query, doseq=True)
            target_url = urlparse.urlunparse(url_parts)
            print("Using API key for authenticated Open-Meteo request.")
        else:
            print("No API key found; proceeding with non-authenticated Open-Meteo call.")
    
    # 3. Fetch Request
    try:
        # Pass through some headers if needed, but typically not required for simple proxies
        proxy_response = requests.get(target_url, verify=True, timeout=10) 
        
        # 4. Construct and Return Response
        
        # Prepare headers for the client
        response_headers = {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET',
            # Set a cache time (5 minutes)
            'Cache-Control': 'public, max-age=300'
        }
        
        # Return the content and status code from the upstream API
        return Response(
            proxy_response.text,
            status=proxy_response.status_code,
            headers=response_headers
        )

    except requests.exceptions.RequestException as e:
        return jsonify({"error": f"Proxy error: {str(e)}"}), 500

if __name__ == '__main__':
    # Flask will run on port 5005, which you will tunnel with Cloudflare
    print("Flask Proxy Server starting on http://127.0.0.1:5005")
    # Setting host='0.0.0.0' allows access from outside localhost (needed for Cloudflare Tunnel)
    app.run(host='0.0.0.0', port=5005, debug=False)
