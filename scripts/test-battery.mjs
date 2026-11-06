import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const html=fs.readFileSync(new URL('../vanilla.html',import.meta.url),'utf8');
assert.match(html,/battery: \{ type: 'battery', refreshInterval: 30000 \}/);
const start=html.indexOf('      function armBatteryRestart()');
const end=html.indexOf('      /*\n       * Weather',start);
const code=html.slice(start,end);
function setup(){
 let timer,armedDelay,output,error,restarts=0,renders=0,now=100000,failRestart=false;
 const context=vm.createContext({Number,Date:{now:()=>now},console,
 setTimeout:(fn,delay)=>{timer=fn;armedDelay=delay;return 1},clearTimeout:()=>{timer=null},render:()=>renders++,
 providers:{outputMap:{battery:{chargePercent:66}},raw:{battery:{
 onOutput:fn=>output=fn,onError:fn=>error=fn,restart:async()=>{restarts++;if(failRestart)throw Error('boom')}
 }}}});
 vm.runInContext('let batteryRestartTimer=null,batteryRetries=0,lastBatteryAt=0;'+
  'const BATTERY_STALE_AFTER_MS=90000,BATTERY_RETRY_BASE_MS=60000,BATTERY_RETRY_MAX_MS=300000;'+code,context);
 return {context,output:value=>output(value),error:()=>error(),get restarts(){return restarts},
  get armed(){return !!timer},get delay(){return armedDelay},set failRestart(value){failRestart=value},
  tick:async()=>{now+=armedDelay;const fn=timer;timer=null;if(fn)await fn()}};
}
const stalled=setup();stalled.output({chargePercent:66});await stalled.tick();assert.equal(stalled.restarts,1,'non-null stalled reading must restart');
stalled.output({chargePercent:73,isCharging:true});assert.equal(vm.runInContext('lastBatteryAt',stalled.context),160000);
const backoff=setup();backoff.output({chargePercent:66});
const delays=[];for(let i=0;i<6;i++){delays.push(backoff.delay);await backoff.tick()}
assert.deepEqual(delays,[60000,120000,240000,300000,300000,300000],'retries widen and then stay bounded');
assert.equal(backoff.restarts,6);assert.equal(backoff.armed,true,'recovery never gives up');
backoff.output({chargePercent:73});assert.equal(backoff.delay,60000,'a good reading resets the delay');assert.equal(vm.runInContext('batteryRetries',backoff.context),0);
const failing=setup();failing.output({chargePercent:66});failing.failRestart=true;await failing.tick();
assert.equal(failing.restarts,1);assert.equal(failing.armed,true,'a failed restart still arms the next attempt');
const first=setup();first.error();await first.tick();assert.equal(first.restarts,1,'first-read errors recover without a cached reading');
const silent=setup();await silent.tick();assert.equal(silent.restarts,1,'no initial event also recovers');
console.log('Battery regression checks passed: 30s polling, stale non-null output, backoff without a cap, failed restart, initial error, silence.');
