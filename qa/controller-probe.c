#include <windows.h>
#include <xinput.h>
#include <mmsystem.h>
#include <stdio.h>
int main(void) {
 for (int retry=0; retry<12; retry++) {
  unsigned connected=0;
  for (DWORD i=0;i<4;i++) { XINPUT_STATE s={0}; DWORD r=XInputGetState(i,&s); printf("xinput[%lu]=%lu buttons=%04x\n",i,r,s.Gamepad.wButtons); if(!r) connected++; }
  printf("joyGetNumDevs=%u connected=%u\n",joyGetNumDevs(),connected); fflush(stdout);
  if(connected) return 0;
  Sleep(500);
 }
 return 2;
}
