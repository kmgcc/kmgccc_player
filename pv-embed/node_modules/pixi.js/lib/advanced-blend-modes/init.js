'use strict';

var Extensions = require('../extensions/Extensions.js');
var ColorBlend = require('./ColorBlend.js');
var ColorBurnBlend = require('./ColorBurnBlend.js');
var ColorDodgeBlend = require('./ColorDodgeBlend.js');
var DarkenBlend = require('./DarkenBlend.js');
var DifferenceBlend = require('./DifferenceBlend.js');
var DivideBlend = require('./DivideBlend.js');
var ExclusionBlend = require('./ExclusionBlend.js');
var HardLightBlend = require('./HardLightBlend.js');
var HardMixBlend = require('./HardMixBlend.js');
var LightenBlend = require('./LightenBlend.js');
var LinearBurnBlend = require('./LinearBurnBlend.js');
var LinearDodgeBlend = require('./LinearDodgeBlend.js');
var LinearLightBlend = require('./LinearLightBlend.js');
var LuminosityBlend = require('./LuminosityBlend.js');
var NegationBlend = require('./NegationBlend.js');
var OverlayBlend = require('./OverlayBlend.js');
var PinLightBlend = require('./PinLightBlend.js');
var SaturationBlend = require('./SaturationBlend.js');
var SoftLightBlend = require('./SoftLightBlend.js');
var SubtractBlend = require('./SubtractBlend.js');
var VividLightBlend = require('./VividLightBlend.js');

"use strict";
Extensions.extensions.add(
  ColorBlend.ColorBlend,
  ColorBurnBlend.ColorBurnBlend,
  ColorDodgeBlend.ColorDodgeBlend,
  DarkenBlend.DarkenBlend,
  DifferenceBlend.DifferenceBlend,
  DivideBlend.DivideBlend,
  ExclusionBlend.ExclusionBlend,
  HardLightBlend.HardLightBlend,
  HardMixBlend.HardMixBlend,
  LightenBlend.LightenBlend,
  LinearBurnBlend.LinearBurnBlend,
  LinearLightBlend.LinearLightBlend,
  LinearDodgeBlend.LinearDodgeBlend,
  LuminosityBlend.LuminosityBlend,
  NegationBlend.NegationBlend,
  OverlayBlend.OverlayBlend,
  PinLightBlend.PinLightBlend,
  SaturationBlend.SaturationBlend,
  SoftLightBlend.SoftLightBlend,
  SubtractBlend.SubtractBlend,
  VividLightBlend.VividLightBlend
);
//# sourceMappingURL=init.js.map
