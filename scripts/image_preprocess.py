import base64
import io
from PIL import Image
import requests

def preprocess_image(image_path: str) -> str:
    # Load image and resize to 224x224 for SigLIP
    image = Image.open(image_path).convert("RGB")
    image = image.resize((224, 224))
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG")
    image_b64 = "data:image/jpeg;base64," + base64.b64encode(buffer.getvalue()).decode()
    return image_b64

def search_image(image_path: str, search_api_url: str):
    image_b64 = preprocess_image(image_path)
    payload = {
        "imageBase64": image_b64,
        "topK": 9
    }
    response = requests.post(search_api_url, json=payload)
    if response.ok:
        print("Search results:", response.json())
    else:
        print("Search failed:", response.text)

if __name__ == "__main__":
    import sys
    if len(sys.argv) < 3:
        print("Usage: python image_preprocess.py <image_path> <search_api_url>")
        sys.exit(1)
    image_path = sys.argv[1]
    search_api_url = sys.argv[2]
    search_image(image_path, search_api_url)