"""Fetch genuine, openly licensed Tokyo footage from Wikimedia Commons (CI only),
verify the licence from Commons metadata, write review frames and an H.264
transcode (AVFoundation cannot play WebM/VP9).  Nothing is purchased."""
import json, subprocess, sys, urllib.parse, urllib.request
from pathlib import Path
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "footage")
UA = "PortalAlley-footage/1.4 (+https://github.com/LeTweaker/PortalAlley.)"
FILES = ["File:Heavy rain in early spring in Tokyo.webm", "File:First nights in Tokyo.webm"]
ALLOWED = ("CC0", "Public domain", "CC BY 4.0", "CC BY 3.0", "CC BY-SA 4.0", "CC BY-SA 3.0")
def get(url, binary=False):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=300) as r:
        d = r.read()
    return d if binary else json.loads(d)
OUT.mkdir(parents=True, exist_ok=True)
records = []
for title in FILES:
    q = get("https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode({
        "action": "query", "format": "json", "titles": title, "prop": "imageinfo",
        "iiprop": "url|size|sha1|extmetadata|mime"}))
    page = next(iter(q["query"]["pages"].values()))
    ii = page["imageinfo"][0]
    em = {k: v.get("value") for k, v in ii["extmetadata"].items()}
    lic = em.get("LicenseShortName", "")
    assert lic in ALLOWED, f"{title}: licence {lic} not allowed"
    stem = title[5:].rsplit(".", 1)[0].replace(" ", "_")
    src = OUT / f"{stem}.webm"
    src.write_bytes(get(ii["url"], binary=True))
    import hashlib
    sha1 = hashlib.sha1(src.read_bytes()).hexdigest()
    assert sha1 == ii["sha1"], "checksum mismatch"
    (OUT / f"{stem}_frames").mkdir(exist_ok=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(src), "-vf", "fps=1/4,scale=480:-2",
                    str(OUT / f"{stem}_frames" / "f%04d.jpg")], check=True)
    dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(src)],
                               capture_output=True, text=True).stdout.strip() or 0)
    if dur > 60:
        # long clips: review frames only; a segment is cut once one is chosen
        records.append(dict(title=title, page=ii["descriptionurl"], url=ii["url"], sha1=sha1, licence=lic,
                            licenceUrl=em.get("LicenseUrl"), artist=em.get("Artist"), credit=em.get("Credit"),
                            date=em.get("DateTimeOriginal"), description=em.get("ImageDescription"), seconds=dur,
                            transcode=None, probe=None))
        src.unlink()
        continue
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(src), "-c:v", "libx264", "-preset", "slow",
                    "-crf", "22", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-c:a", "aac", "-b:a", "128k",
                    str(OUT / f"{stem}.mp4")], check=True)
    probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_name,width,height,r_frame_rate",
                            "-of", "json", str(OUT / f"{stem}.mp4")], capture_output=True, text=True).stdout
    records.append(dict(title=title, page=ii["descriptionurl"], url=ii["url"], sha1=sha1, licence=lic,
                        licenceUrl=em.get("LicenseUrl"), artist=em.get("Artist"), credit=em.get("Credit"),
                        date=em.get("DateTimeOriginal"), description=em.get("ImageDescription"),
                        transcode=f"{stem}.mp4", probe=json.loads(probe)))
    src.unlink()      # keep the review branch small: frames + H.264 only
(OUT / "footage.json").write_text(json.dumps(records, indent=1, ensure_ascii=False))
print(json.dumps(records, indent=1, ensure_ascii=False)[:4000])
