// Kigyűjti a HU→EN szótárt felépítő utasításokat, PONTOSAN abban a sorrendben,
// ahogy az app.jsx futtatja őket, és futtatható modulként kiírja.
import {readFileSync,writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname} from 'node:path';
// a projekt gyökere: .../supabase/diagnostics/i18n -> három szinttel feljebb
const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = HERE + '/../../../';
const lines=readFileSync(ROOT+'app.jsx','utf8').split('\n');
const find=(re,from=0)=>{for(let i=from;i<lines.length;i++)if(re.test(lines[i]))return i;return -1;};
const closeFrom=(i,open,close)=>{let d=0,s=false;
  for(let j=i;j<lines.length;j++){let inq=null;const l=lines[j];
    for(let k=0;k<l.length;k++){const c=l[k];
      if(inq){if(c==='\\'){k++;continue;}if(c===inq)inq=null;continue;}
      if(c==="'"||c==='"'||c==='`'){inq=c;continue;}
      if(c===open){d++;s=true;}else if(c===close)d--;}
    if(s&&d<=0)return j;}
  return -1;};
const seg=(a,b)=>lines.slice(a,b+1).join('\n');
const si=find(/^const STATUS_I18N = \{/);
const hi=find(/^const HU_EN = \{/);
const setup=find(/^\(function setupI18n\(\)\{/);
const out=[seg(si,closeFrom(si,'{','}')), seg(hi,setup-1), 'export {HU_EN, HU_EN_PHRASES, STATUS_I18N};'].join('\n');
writeFileSync(HERE+'/.dicteval.mjs',out);
console.log('szótár-modul kiírva; sorok:',si+1,hi+1,setup);
