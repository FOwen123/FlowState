// Photo stays recognizable; a fine sampled grid carries a slow travelling light field.
const canvas=document.getElementById('woodland'),ctx=canvas.getContext('2d');
const photo=new Image(),sample=document.createElement('canvas'),sx=sample.getContext('2d',{willReadFrequently:true});
const reduced=matchMedia('(prefers-reduced-motion: reduce)');
let pixels,w,h,cols,rows,phase=0,last=0;
function resize(){
 w=canvas.width=innerWidth;h=canvas.height=innerHeight;
 cols=sample.width=Math.ceil(w/5);rows=sample.height=Math.ceil(h/5);
 const scale=Math.max(w/photo.width,h/photo.height),dw=photo.width*scale,dh=photo.height*scale;
 sx.drawImage(photo,(w-dw)/10,(h-dh)/10,dw/5,dh/5);
 pixels=sx.getImageData(0,0,cols,rows).data;draw();
}
function draw(){
 const scale=Math.max(w/photo.width,h/photo.height),dw=photo.width*scale,dh=photo.height*scale;
 ctx.globalAlpha=1;ctx.drawImage(photo,(w-dw)/2,(h-dh)/2,dw,dh);
 for(let y=0;y<rows;y++)for(let x=0;x<cols;x++){
  const i=(y*cols+x)*4,light=(Math.sin(x*.045+y*.025-phase)+1)/2;
  ctx.fillStyle=`rgba(${pixels[i]},${pixels[i+1]},${pixels[i+2]},${.12+light*.18})`;
  ctx.fillRect(x*5,y*5,3,3);
 }
 canvas.dataset.ready='true';
}
function tick(now){
 if(now-last>40){
  if(pixels && !reduced.matches && !document.body.classList.contains('paused') && document.body.dataset.scene==='scenery'){phase+=Math.min(now-last,100)*.00035;draw();}
  last=now;
 }
 requestAnimationFrame(tick);
}
photo.onload=()=>{resize();addEventListener('resize',resize);requestAnimationFrame(tick);};
photo.src=window.woodlandSource;
