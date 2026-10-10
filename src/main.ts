import Phaser from 'phaser';
import { VIEW } from './config';
import { BootScene } from './scenes/BootScene';
import { GameScene } from './scenes/GameScene';
import { TitleScene } from './scenes/TitleScene';

new Phaser.Game({
  type: Phaser.AUTO,
  parent: 'game',
  width: VIEW.width,
  height: VIEW.height,
  backgroundColor: '#000000',
  // Pixel art: nearest-neighbour scaling, no antialiasing, and unscaled objects snap to whole pixels.
  pixelArt: true,
  // The MVP has no audio. noAudio stops Phaser from setting up its Web Audio system at all.
  audio: { noAudio: true },
  scale: {
    mode: Phaser.Scale.FIT,
    autoCenter: Phaser.Scale.CENTER_BOTH,
  },
  // Boot loads the sprites and the font, then starts Title.
  scene: [BootScene, TitleScene, GameScene],
});
