from PIL import Image
import os, base64, io, html

FRAMES = '/Users/ian/dev/procwatch/assets/frames2/kiwi'
OUT    = '/Users/ian/dev/procwatch/docs/kiwi-rendering.html'

# 후보 비교용 갤러리를 만들 때 쓴 근사 고정값이며 앱은 이 값을 채택하지 않았다.
# 앱의 빨강은 NSColor.systemRed 이고, 실제 렌더 값은 외형에 따라 시스템이 정한다.
RED_LIGHT = (255, 59, 48)
RED_DARK  = (255, 69, 58)

def load():
    return [Image.open(f'{FRAMES}/{f}').convert('RGBA') for f in sorted(os.listdir(FRAMES))]

def to22(im):
    return im.resize((max(1, round(im.width * 22 / im.height)), 22), Image.NEAREST)

def tint(fs, rgb):
    # macOS template image 와 같은 단색 렌더. 알파만 실루엣으로 남긴다.
    out = []
    for f in fs:
        a = f.split()[3].point(lambda v: 255 if v > 128 else 0)
        m = Image.new('RGBA', f.size, rgb + (0,))
        m.putalpha(a)
        out.append(m)
    return out

def gif(fs, dur):
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
    return 'data:image/gif;base64,' + base64.b64encode(buf.getvalue()).decode()

fr = [to22(f) for f in load()]
SLOW, FAST = 220, 60
g = {
    'color_slow':  gif(fr, SLOW),                    'color_fast':  gif(fr, FAST),
    'black_slow':  gif(tint(fr, (0, 0, 0)), SLOW),   'black_fast':  gif(tint(fr, (0, 0, 0)), FAST),
    'white_slow':  gif(tint(fr, (255,)*3), SLOW),    'white_fast':  gif(tint(fr, (255,)*3), FAST),
    'redl_fast':   gif(tint(fr, RED_LIGHT), FAST),
    'redd_fast':   gif(tint(fr, RED_DARK), FAST),
}

# (옵션 제목, 설명, 라이트 평상시, 라이트 폭주, 다크 평상시, 다크 폭주)
OPTIONS = [
 ('A. 항상 단색',
  'RunCat 과 같은 방식입니다. macOS 가 배경에 맞춰 자동으로 검정·흰색을 뒤집어 주므로 어떤 배경에서도 묻히지 않고, 시스템 아이콘들과 한 줄로 자연스럽게 섞입니다. 대신 폭주를 걸음 속도만으로 알려야 합니다.',
  'black_slow', 'black_fast', 'white_slow', 'white_fast'),
 ('B. 평상시 단색 + 폭주할 때만 빨강',
  '평소에는 A 와 똑같이 조용히 섞여 있다가, 폭주를 잡은 순간에만 빨갛게 바뀝니다. 색이 평상시에 낭비되지 않고 경고에만 쓰입니다.',
  'black_slow', 'redl_fast', 'white_slow', 'redd_fast'),
 ('C. 항상 컬러',
  '키위새 원본 색을 그대로 씁니다. 눈에 잘 띄지만 메뉴바에서 혼자 튀고, 폭주 상태를 색으로 알릴 여지가 남지 않습니다.',
  'color_slow', 'color_fast', 'color_slow', 'color_fast'),
]

def bar(theme, normal, alert):
    return f'''
        <div class="bar {theme}">
          <span class="bar-label">{'라이트' if theme == 'light' else '다크'}</span>
          <span class="mb">
            <span class="slot"><img src="{g[normal]}" alt="평상시"><em>평상시</em></span>
            <span class="slot"><img src="{g[alert]}" alt="폭주 감지"><em>폭주 감지</em></span>
            <span class="sys">100%</span>
            <span class="sys">화 오후 5:42</span>
          </span>
        </div>'''

cards = []
for i, (title, desc, ln, la, dn, da) in enumerate(OPTIONS, 1):
    cards.append(f'''
    <section class="card">
      <header class="card-head"><span class="num">{i}</span><h2>{html.escape(title)}</h2></header>
      <p class="note">{html.escape(desc)}</p>
      <div class="bars">
{bar('light', ln, la)}
{bar('dark', dn, da)}
      </div>
    </section>''')

doc = f'''<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>키위새 렌더 방식 비교</title>
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
  .lead {{ color: var(--muted); margin: 0 0 32px; }}
  .card {{
    width: 100%; background: var(--card); border: 1px solid var(--line);
    border-radius: 10px; padding: 22px; margin: 0 0 20px;
  }}
  .card-head {{ display: flex; align-items: center; gap: 10px; margin-bottom: 6px; }}
  .num {{
    flex: none; display: inline-grid; place-items: center;
    width: 26px; height: 26px; border-radius: 50%;
    background: var(--accent); color: var(--bg); font-size: 0.85rem; font-weight: 700;
  }}
  .card-head h2 {{ font-size: 1.1rem; margin: 0; }}
  .note {{ color: var(--muted); margin: 0 0 18px; font-size: 0.92rem; }}

  .bars {{ width: 100%; display: grid; gap: 8px; }}
  .bar {{
    width: 100%; display: flex; align-items: center; justify-content: space-between;
    gap: 12px; border-radius: 6px; padding: 8px 14px; font-size: 0.8rem;
  }}
  .bar.light {{ background: #f2f2f2; color: #3a3a3a; border: 1px solid #dcdcdc; }}
  .bar.dark  {{ background: #2b2b2b; color: #dcdcdc; border: 1px solid #3c3c3c; }}
  .bar-label {{ flex: none; opacity: .55; font-size: 0.75rem; }}
  .mb {{ display: flex; align-items: center; gap: 20px; }}
  .slot {{ display: flex; flex-direction: column; align-items: center; gap: 2px; }}
  .slot img {{ height: 22px; width: auto; image-rendering: pixelated; display: block; }}
  .slot em {{ font-style: normal; font-size: 0.65rem; opacity: .5; }}
  .sys {{ font-size: 0.8rem; opacity: .8; }}

  @media (max-width: 560px) {{
    .wrap {{ padding: 32px 16px 60px; }}
    .bar {{ flex-direction: column; align-items: flex-start; gap: 10px; }}
    .mb {{ gap: 14px; flex-wrap: wrap; }}
  }}
</style>
</head>
<body>
<div class="wrap">
  <h1>키위새를 어떻게 그릴까</h1>
  <p class="lead">RunCat 의 내장 러너는 전부 단색입니다. 키위새도 그렇게 할지, 색을 남길지 세 가지로 비교했습니다. 실제 메뉴바 높이(22px) 그대로입니다.</p>
{''.join(cards)}
</div>
</body>
</html>
'''
open(OUT, 'w').write(doc)
print(OUT, f'{os.path.getsize(OUT)/1024:.0f} KB')
