const {chromium}=require('@playwright/test');
const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
(async()=>{
const browser=await chromium.launch({headless:true,channel:'chrome'});
try{
 const page=await browser.newPage({viewport:{width:1440,height:900},reducedMotion:'no-preference'});
 page.setDefaultTimeout(3000);
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(pathToFileURL(path.join(__dirname,'forest-living-pixels.html')).href);
 const canvas=page.locator('canvas.forest');
 assert.equal(await canvas.count(),1,'one continuous pixel field fills the background');
 async function frame(){return canvas.evaluate(c=>{
  const {width:w,height:h}=c;const pixels=c.getContext('2d').getImageData(0,0,w,h).data;
  const regions=[[],[],[],[],[]];
  for(let y=0;y<h;y+=3)for(let x=0;x<w;x+=3){
   const green=pixels[(y*w+x)*4+1];
   if(x<w*.2)regions[0].push(green);if(x>w*.8)regions[1].push(green);
   if(y<h*.15)regions[2].push(green);if(y>h*.8)regions[3].push(green);
   if(x>w*.4&&x<w*.6&&y>h*.3&&y<h*.6)regions[4].push(green);
  }
  return regions;
 });}
 await page.waitForTimeout(200);const a=await frame();
 await page.waitForTimeout(1300);const b=await frame();
 for(let i=0;i<4;i++)assert.ok(a[i].filter((v,j)=>Math.abs(v-b[i][j])>3).length>a[i].length*.03,'motion reaches each edge of the background');
 const mean=a=>a.reduce((s,v)=>s+v,0)/a.length;
 assert.ok(mean(b[4])<mean(b[0])*.65,'headline clearing stays dark');
 await page.getByRole('button',{name:'Pause motion'}).click();
 const paused=await frame();await page.waitForTimeout(200);assert.deepEqual(await frame(),paused,'pause freezes the rendered field');
 await page.screenshot({path:path.join(__dirname,'forest-preview.png')});
 await page.getByRole('button',{name:'Resume motion'}).click();await page.waitForTimeout(200);assert.notDeepEqual(await frame(),paused,'resume advances the field');
 await page.getByRole('button',{name:'Hide copy'}).click();assert.equal(await page.locator('main').isVisible(),false);
 await page.getByRole('button',{name:'Show copy'}).click();
 await page.emulateMedia({reducedMotion:'reduce'});await page.waitForTimeout(100);
 const reduced=await frame();await page.waitForTimeout(200);assert.deepEqual(await frame(),reduced);
 await page.getByRole('button',{name:'Play animation'}).click();await page.waitForTimeout(300);assert.notDeepEqual(await frame(),reduced);
 await page.setViewportSize({width:390,height:844});await page.waitForTimeout(150);
 assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 assert.deepEqual(await canvas.evaluate(c=>({width:c.width,height:c.height})),{width:390,height:844},'canvas tracks the whole viewport without stretching its pixel grid');
 await page.screenshot({path:path.join(__dirname,'forest-mobile.png')});
 assert.deepEqual(errors,[]);
 console.log('PASS: full-background motion at all four edges, dark clearing, pause/resume, reduced-motion opt-in, mobile sizing, no runtime errors.');
}finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
