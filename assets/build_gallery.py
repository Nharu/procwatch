from PIL import Image
import os, json, base64, io, html, sys

SETS = {
 'wide': dict(
   frames = '/tmp/frames',
   order  = ['cat','kiwi','penguin','rat','beaver','slime','robot','fly','dino'],
   out    = '/Users/ian/dev/procwatch/docs/sprite-candidates.html',
   title  = '메뉴바 캐릭터 후보 9종',
   lead   = '폭주 감시기(procwatch)가 메뉴바에서 쓸 도트 캐릭터입니다. 전부 재배포·개작이 가능한 공개 에셋입니다.',
 ),
 'kiwi': dict(
   frames = '/tmp/frames2',
   order  = ['kiwi','chick','chicken','dog','shepherd','husky','snake'],
   out    = '/Users/ian/dev/procwatch/docs/sprite-candidates-kiwi.html',
   title  = '키위새 계열 후보 7종',
   lead   = '고르신 키위새와 같은 계열 — 작고 굵은 실루엣의 옆모습 걷기입니다. 맨 위가 기준인 키위새이고, 나머지 여섯은 대부분 같은 작가의 다른 동물입니다.',
 ),
}
SET = SETS[sys.argv[1] if len(sys.argv) > 1 else 'wide']

META = json.load(open(f"{SET['frames']}/meta.json")); META.pop('turtle', None)
ORDER = SET['order']

LIC = {
 'cat':    ('Shepardskin', 'CC0'),
 'kiwi':   ('Shepardskin', 'CC0'),
 'penguin':('Spring Spring', 'CC0'),
 'rat':    ('Prinsu-kun', 'CC-BY 3.0'),
 'beaver': ('bleutailfly', 'CC0'),
 'slime':  ('rvros', 'CC0'),
 'robot':  ('Stratofortress', 'CC0'),
 'fly':    ('ARoachIFoundOnMyPillow', 'CC0'),
 'dino':   ('pzUH', 'CC0'),
 'chick':  ('Jordan Irwin (Shepardskin 원작)', 'CC0'),
 'chicken':('Shepardskin', 'CC0'),
 'dog':    ('Shepardskin', 'CC0'),
 'shepherd':('Shepardskin', 'CC0'),
 'husky':  ('Shepardskin', 'CC0'),
 'snake':  ('Shepardskin', 'CC0'),
}
NOTE = {
 'cat':    '지난번에 보여드린 것. 가장 RunCat 에 가까움',
 'kiwi':   '가장 단순한 축. 선이 굵고 실루엣이 또렷함',
 'penguin':'프레임이 10장이라 걸음이 부드러움',
 'rat':    '유일한 CC-BY — 앱 정보창에 저자 표기가 필요. 팔을 휘젓는 4프레임',
 'beaver': '납작한 옆모습이라 메뉴바 높이에 잘 맞음',
 'slime':  '다리가 없어 픽셀이 거의 안 흔들림. 가장 미니멀',
 'robot':  '기계적인 느낌. 개발자스러움 쪽',
 'fly':    '3프레임 날갯짓. 극단적으로 단순',
 'dino':   '원본이 큼(423px) — 22px 로 줄이면 뭉개질 수 있음',
 'chick':  '키위새와 가장 닮은 덩어리 실루엣. 프레임이 7장이라 걸음이 부드러움',
 'chicken':'키위새와 같은 작가·같은 크기대. 볏과 꼬리가 실루엣의 포인트',
 'dog':    '16x10 으로 후보 중 가장 납작해 메뉴바 높이에 잘 맞음',
 'shepherd':'키위새와 정확히 같은 24x16. 다리가 길어 걸음이 또렷함',
 'husky':  '72x48 로 가장 큼 — 22px 로 줄이면 눈·코 디테일이 뭉갤 수 있음',
 'snake':  '몸을 세운 자세라 세로로 길다. 22px 에 맞추면 가로가 좁아져 존재감이 약함',
}

def load(k):
    d = f"{SET['frames']}/{k}"
    return [Image.open(f'{d}/{f}').convert('RGBA') for f in sorted(os.listdir(d))]

def to_h(im, h, resample):
    if im.height == h: return im
    return im.resize((max(1, round(im.width * h / im.height)), h), resample)

def pack(fs, dur):
    W = max(f.width for f in fs); H = max(f.height for f in fs)
    conv = []
    for f in fs:
        c = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        c.paste(f, ((W - f.width) // 2, (H - f.height) // 2), f)
        p = c.convert('P', palette=Image.ADAPTIVE, colors=255)
        p.paste(255, c.split()[3].point(lambda a: 255 if a <= 128 else 0))
        conv.append(p)
    buf = io.BytesIO()
    conv[0].save(buf, format='GIF', save_all=True, append_images=conv[1:],
                 duration=dur, loop=0, transparency=255, disposal=2, optimize=False)
    return base64.b64encode(buf.getvalue()).decode()

def bar22(fr, dur):
    # 실제 메뉴바 높이. 원본이 크면 LANCZOS 축소가 NEAREST 보다 덜 깨진다.
    return [to_h(f, 22, Image.LANCZOS if f.height > 44 else Image.NEAREST) for f in fr]

def mono(fs, rgb):
    # macOS template image 와 같은 단색 렌더. 알파만 실루엣으로 남긴다.
    out = []
    for f in fs:
        a = f.split()[3].point(lambda v: 255 if v > 128 else 0)
        m = Image.new('RGBA', f.size, rgb + (0,))
        m.putalpha(a)
        out.append(m)
    return out

def zoom(fr):
    # 22px 를 거치지 않고 원본에서 바로 확대해야 도트가 살아난다.
    h = fr[0].height
    if h >= 120:
        fs = [to_h(f, 120, Image.LANCZOS) for f in fr]
    else:
        s = max(1, round(120 / h))
        fs = [f.resize((f.width * s, f.height * s), Image.NEAREST) for f in fr]
    return pack(fs, 180)

rows = []
for i, k in enumerate(ORDER, 1):
    fr = load(k)
    author, lic = LIC[k]
    slow, fast = bar22(fr, 220), bar22(fr, 60)
    g = dict(
        big  = zoom(fr),
        slow = pack(slow, 220), fast = pack(fast, 60),
        mdark  = pack(mono(slow, (255, 255, 255)), 220),
        mlight = pack(mono(slow, (0, 0, 0)), 220),
    )
    rows.append(f'''
    <section class="card" id="c{i}">
      <header class="card-head">
        <span class="num">{i}</span>
        <h2>{html.escape(META[k]['label'])}</h2>
        <span class="meta">{len(fr)}프레임 · {fr[0].width}x{fr[0].height}px · {lic} · {html.escape(author)}</span>
      </header>
      <p class="note">{html.escape(NOTE[k])}</p>
      <div class="zoom"><img src="data:image/gif;base64,{g['big']}" alt="{html.escape(META[k]['label'])} 확대"></div>
      <div class="bars">
        <div class="bar light">
          <span class="bar-label">컬러 · 라이트</span>
          <span class="mb">
            <img class="mbimg" src="data:image/gif;base64,{g['slow']}" alt="평상시">
            <img class="mbimg" src="data:image/gif;base64,{g['fast']}" alt="폭주">
            <span class="mbtxt">100%</span>
          </span>
        </div>
        <div class="bar dark">
          <span class="bar-label">컬러 · 다크</span>
          <span class="mb">
            <img class="mbimg" src="data:image/gif;base64,{g['slow']}" alt="평상시">
            <img class="mbimg" src="data:image/gif;base64,{g['fast']}" alt="폭주">
            <span class="mbtxt">100%</span>
          </span>
        </div>
        <div class="bar light">
          <span class="bar-label">단색 · 라이트</span>
          <span class="mb">
            <img class="mbimg" src="data:image/gif;base64,{g['mlight']}" alt="단색 실루엣">
            <span class="mbtxt">100%</span>
          </span>
        </div>
        <div class="bar dark">
          <span class="bar-label">단색 · 다크</span>
          <span class="mb">
            <img class="mbimg" src="data:image/gif;base64,{g['mdark']}" alt="단색 실루엣">
            <span class="mbtxt">100%</span>
          </span>
        </div>
      </div>
      <p class="cap">컬러 줄은 왼쪽이 평상시(느린 걸음), 오른쪽이 폭주 감지(빠른 걸음). 단색 줄은 macOS 표준 방식으로 실루엣만 남긴 모습입니다.</p>
    </section>''')
    print(f'{k:9} {len(fr)}프레임 {fr[0].size}')

doc = f'''<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>procwatch 메뉴바 캐릭터 후보</title>
<style>
  :root {{
    --bg: #ffffff; --fg: #1a1a1a; --muted: #666;
    --line: #e2e2e2; --card: #fafafa; --accent: #2f6f4f;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --bg: #16181c; --fg: #e8e8e8; --muted: #9a9a9a;
      --line: #2e3238; --card: #1d2026; --accent: #7fd1a4;
    }}
  }}
  * {{ box-sizing: border-box; }}
  html, body {{ margin: 0; padding: 0; }}
  body {{
    background: var(--bg); color: var(--fg);
    font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif;
    line-height: 1.7; word-break: keep-all; overflow-wrap: anywhere;
  }}
  .wrap {{ max-width: 780px; margin: 0 auto; padding: 48px 20px 80px; }}
  h1 {{ font-size: 1.7rem; margin: 0 0 8px; letter-spacing: -0.02em; }}
  .lead {{ color: var(--muted); margin: 0; }}
  .howto {{
    width: 100%; background: var(--card);
    border: 1px solid var(--line); border-left: 3px solid var(--accent);
    border-radius: 6px; padding: 14px 18px; margin: 24px 0 40px; font-size: 0.95rem;
  }}
  .howto p {{ margin: 0; }}
  .howto p + p {{ margin-top: 8px; }}
  .howto strong {{ color: var(--accent); }}

  .card {{
    width: 100%; background: var(--card); border: 1px solid var(--line);
    border-radius: 10px; padding: 22px; margin: 0 0 24px;
  }}
  .card-head {{ display: flex; align-items: baseline; flex-wrap: wrap; gap: 10px; margin-bottom: 4px; }}
  .num {{
    flex: none; display: inline-grid; place-items: center;
    width: 26px; height: 26px; border-radius: 50%;
    background: var(--accent); color: var(--bg);
    font-size: 0.85rem; font-weight: 700; align-self: center;
  }}
  .card-head h2 {{ font-size: 1.15rem; margin: 0; }}
  .meta {{ color: var(--muted); font-size: 0.82rem; }}
  .note {{ color: var(--muted); margin: 0 0 16px; font-size: 0.92rem; }}

  .zoom {{
    width: 100%; display: grid; place-items: center;
    /* 중간톤 배경이라야 흰 스프라이트와 검은 스프라이트가 둘 다 보인다. */
    background:
      repeating-conic-gradient(rgba(255,255,255,.13) 0% 25%, transparent 0% 50%) 50% / 16px 16px,
      #8b8f94;
    border: 1px solid var(--line); border-radius: 8px;
    padding: 20px 8px; margin-bottom: 14px; min-height: 160px;
  }}
  .zoom img {{ image-rendering: pixelated; max-width: 100%; height: auto; }}

  .bars {{ width: 100%; display: grid; gap: 6px; }}
  .bar {{
    width: 100%; display: flex; align-items: center; justify-content: space-between;
    gap: 12px; border-radius: 6px; padding: 5px 12px; font-size: 0.8rem;
  }}
  .bar.light {{ background: #f2f2f2; color: #444; border: 1px solid #dcdcdc; }}
  .bar.dark  {{ background: #2b2b2b; color: #ddd; border: 1px solid #3c3c3c; }}
  .bar-label {{ flex: none; opacity: .65; font-size: 0.75rem; }}
  .mb {{ display: flex; align-items: center; gap: 14px; }}
  .mbimg {{ height: 22px; width: auto; image-rendering: pixelated; display: block; }}
  .mbtxt {{ font-size: 0.78rem; opacity: .75; }}
  .cap {{ color: var(--muted); font-size: 0.8rem; margin: 12px 0 0; }}

  @media (max-width: 520px) {{
    .wrap {{ padding: 32px 16px 60px; }}
    .bar {{ flex-direction: column; align-items: flex-start; gap: 6px; }}
  }}
</style>
</head>
<body>
<div class="wrap">
  <h1>{html.escape(SET['title'])}</h1>
  <p class="lead">{html.escape(SET['lead'])}</p>

  <div class="howto">
    <p><strong>번호로 알려주세요.</strong> 마음에 드는 게 없으면 그것도 알려주시면 방향을 좁혀서 다시 찾아 드립니다.</p>
    <p>확대 그림은 원본을 키운 것이고, 아래 네 줄이 실제 메뉴바에 올라갈 22px 크기입니다. 컬러를 그대로 쓸지 macOS 표준대로 단색 실루엣으로 쓸지도 함께 골라주시면 됩니다.</p>
  </div>
{''.join(rows)}
</div>
</body>
</html>
'''
out = SET['out']
open(out, 'w').write(doc)
print(out, f'{os.path.getsize(out)/1024:.0f} KB')
