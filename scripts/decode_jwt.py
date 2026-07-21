import base64
import json

def decode_jwt(token):
    try:
        parts = token.split('.')
        if len(parts) != 3:
            print("Hata: Geçersiz JWT formatı.")
            return

        header = parts[0]
        payload = parts[1]

        def b64_decode(data):
            missing_padding = len(data) % 4
            if missing_padding:
                data += '=' * (4 - missing_padding)
            return base64.urlsafe_b64decode(data).decode()

        print("--- HEADER ---")
        print(json.dumps(json.loads(b64_decode(header)), indent=2))
        print("\n--- PAYLOAD ---")
        print(json.dumps(json.loads(b64_decode(payload)), indent=2))

    except Exception as e:
        print(f"Hata: {e}")

token = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6IkhtZkdPOFBGSUhaZGpQaGxkLV9lWiJ9.eyJodHRwczovL2F1dGguZHZpbmEuYWkvY2xhaW1zIjp7ImZpcnN0bmFtZSI6IlNlbm9sIiwibGFuZ3VhZ2UiOiJlbiIsInJvbGUiOiJBZG1pbiIsIndvcmtzcGFjZUlkIjoib3JnX00yekpGY29RYzd1RnB6Q2IifSwiaXNzIjoiaHR0cHM6Ly9hdXRoLmR2aW5hLmFpLyIsInN1YiI6Imdvb2dsZS1vYXV0aDJ8MTAxMzgzODA2MTA3ODk5MzEyMTI5IiwiYXVkIjpbImh0dHBzOi8vYXBpLmR2aW5hLmFpIiwiaHR0cHM6Ly9kZXYtb2EyeGFodGp3cXFpc25jNS51cy5hdXRoMC5jb20vdXNlcmluZm8iXSwiaWF0IjoxNzcyODIwNzQxLCJleHAiOjE3NzI5MDcxNDEsInNjb3BlIjoib3BlbmlkIHByb2ZpbGUgZW1haWwgb2ZmbGluZV9hY2Nlc3MiLCJhenAiOiJPd2RBZFpxbExwMjlvN2dkNzFRNzNySG5pckhwRHdtcCJ9.hi_ROrjFZvXMuczPdHpHXj0w5xflS-ovlA7cAPp1C5BjJbGjZ0BBZMeOk8aGE4CeJxzcIeiznzMSzNs3Wdc4Lr-xqhgPrZXcyHBYGTFK5YXRiomBribpnUboeDsZfyBlKv4CphUyUEzdi-CndOBrAl0inEiG1hzBnjMjgx4IT4TOtZGJTTgONRNkeLmeNgRixyiPWVwQCncp7VEZHf6Bz-49rgM6_1hRkgykbIxFeVvDuGMSFq42P9NysQEFJoQZVVNU86D78jP-0S1HVIrLjwLTm0dP8rXliVHY7OnLuudMLFXsIdERDJ0i3grU9T9EK6uPRcsiZQ68qM9pHNhwEw"
decode_jwt(token)
