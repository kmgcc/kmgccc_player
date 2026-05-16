Math.PI / 180;
180 / Math.PI;
//#endregion
//#region ../../node_modules/.pnpm/gl-matrix@4.0.0-beta.2/node_modules/gl-matrix/dist/esm/mat4.js
const IDENTITY_4X4 = new Float32Array([
	1,
	0,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	0,
	1
]);
/**
* A 4x4 Matrix
*/
var Mat4 = class Mat4 extends Float32Array {
	/**
	* The number of bytes in a {@link Mat4}.
	*/
	static BYTE_LENGTH = 16 * Float32Array.BYTES_PER_ELEMENT;
	/**
	* Create a {@link Mat4}.
	*/
	constructor(...values) {
		switch (values.length) {
			case 16:
				super(values);
				break;
			case 2:
				super(values[0], values[1], 16);
				break;
			case 1:
				const v = values[0];
				if (typeof v === "number") super([
					v,
					v,
					v,
					v,
					v,
					v,
					v,
					v,
					v,
					v,
					v,
					v,
					v,
					v,
					v,
					v
				]);
				else super(v, 0, 16);
				break;
			default:
				super(IDENTITY_4X4);
				break;
		}
	}
	/**
	* A string representation of `this`
	* Equivalent to `Mat4.str(this);`
	*/
	get str() {
		return Mat4.str(this);
	}
	/**
	* Copy the values from another {@link Mat4} into `this`.
	*
	* @param a the source vector
	* @returns `this`
	*/
	copy(a) {
		this.set(a);
		return this;
	}
	/**
	* Set `this` to the identity matrix
	* Equivalent to Mat4.identity(this)
	*
	* @returns `this`
	*/
	identity() {
		this.set(IDENTITY_4X4);
		return this;
	}
	/**
	* Multiplies this {@link Mat4} against another one
	* Equivalent to `Mat4.multiply(this, this, b);`
	*
	* @param out - The receiving Matrix
	* @param a - The first operand
	* @param b - The second operand
	* @returns `this`
	*/
	multiply(b) {
		return Mat4.multiply(this, this, b);
	}
	/**
	* Alias for {@link Mat4.multiply}
	*/
	mul(b) {
		return this;
	}
	/**
	* Transpose this {@link Mat4}
	* Equivalent to `Mat4.transpose(this, this);`
	*
	* @returns `this`
	*/
	transpose() {
		return Mat4.transpose(this, this);
	}
	/**
	* Inverts this {@link Mat4}
	* Equivalent to `Mat4.invert(this, this);`
	*
	* @returns `this`
	*/
	invert() {
		return Mat4.invert(this, this);
	}
	/**
	* Translate this {@link Mat4} by the given vector
	* Equivalent to `Mat4.translate(this, this, v);`
	*
	* @param v - The {@link Vec3} to translate by
	* @returns `this`
	*/
	translate(v) {
		return Mat4.translate(this, this, v);
	}
	/**
	* Rotates this {@link Mat4} by the given angle around the given axis
	* Equivalent to `Mat4.rotate(this, this, rad, axis);`
	*
	* @param rad - the angle to rotate the matrix by
	* @param axis - the axis to rotate around
	* @returns `out`
	*/
	rotate(rad, axis) {
		return Mat4.rotate(this, this, rad, axis);
	}
	/**
	* Scales this {@link Mat4} by the dimensions in the given vec3 not using vectorization
	* Equivalent to `Mat4.scale(this, this, v);`
	*
	* @param v - The {@link Vec3} to scale the matrix by
	* @returns `this`
	*/
	scale(v) {
		return Mat4.scale(this, this, v);
	}
	/**
	* Rotates this {@link Mat4} by the given angle around the X axis
	* Equivalent to `Mat4.rotateX(this, this, rad);`
	*
	* @param rad - the angle to rotate the matrix by
	* @returns `this`
	*/
	rotateX(rad) {
		return Mat4.rotateX(this, this, rad);
	}
	/**
	* Rotates this {@link Mat4} by the given angle around the Y axis
	* Equivalent to `Mat4.rotateY(this, this, rad);`
	*
	* @param rad - the angle to rotate the matrix by
	* @returns `this`
	*/
	rotateY(rad) {
		return Mat4.rotateY(this, this, rad);
	}
	/**
	* Rotates this {@link Mat4} by the given angle around the Z axis
	* Equivalent to `Mat4.rotateZ(this, this, rad);`
	*
	* @param rad - the angle to rotate the matrix by
	* @returns `this`
	*/
	rotateZ(rad) {
		return Mat4.rotateZ(this, this, rad);
	}
	/**
	* Generates a perspective projection matrix with the given bounds.
	* The near/far clip planes correspond to a normalized device coordinate Z range of [-1, 1],
	* which matches WebGL/OpenGL's clip volume.
	* Passing null/undefined/no value for far will generate infinite projection matrix.
	* Equivalent to `Mat4.perspectiveNO(this, fovy, aspect, near, far);`
	*
	* @param fovy - Vertical field of view in radians
	* @param aspect - Aspect ratio. typically viewport width/height
	* @param near - Near bound of the frustum
	* @param far - Far bound of the frustum, can be null or Infinity
	* @returns `this`
	*/
	perspectiveNO(fovy, aspect, near, far) {
		return Mat4.perspectiveNO(this, fovy, aspect, near, far);
	}
	/**
	* Generates a perspective projection matrix suitable for WebGPU with the given bounds.
	* The near/far clip planes correspond to a normalized device coordinate Z range of [0, 1],
	* which matches WebGPU/Vulkan/DirectX/Metal's clip volume.
	* Passing null/undefined/no value for far will generate infinite projection matrix.
	* Equivalent to `Mat4.perspectiveZO(this, fovy, aspect, near, far);`
	*
	* @param fovy - Vertical field of view in radians
	* @param aspect - Aspect ratio. typically viewport width/height
	* @param near - Near bound of the frustum
	* @param far - Far bound of the frustum, can be null or Infinity
	* @returns `this`
	*/
	perspectiveZO(fovy, aspect, near, far) {
		return Mat4.perspectiveZO(this, fovy, aspect, near, far);
	}
	/**
	* Generates a orthogonal projection matrix with the given bounds.
	* The near/far clip planes correspond to a normalized device coordinate Z range of [-1, 1],
	* which matches WebGL/OpenGL's clip volume.
	* Equivalent to `Mat4.orthoNO(this, left, right, bottom, top, near, far);`
	*
	* @param left - Left bound of the frustum
	* @param right - Right bound of the frustum
	* @param bottom - Bottom bound of the frustum
	* @param top - Top bound of the frustum
	* @param near - Near bound of the frustum
	* @param far - Far bound of the frustum
	* @returns `this`
	*/
	orthoNO(left, right, bottom, top, near, far) {
		return Mat4.orthoNO(this, left, right, bottom, top, near, far);
	}
	/**
	* Generates a orthogonal projection matrix with the given bounds.
	* The near/far clip planes correspond to a normalized device coordinate Z range of [0, 1],
	* which matches WebGPU/Vulkan/DirectX/Metal's clip volume.
	* Equivalent to `Mat4.orthoZO(this, left, right, bottom, top, near, far);`
	*
	* @param left - Left bound of the frustum
	* @param right - Right bound of the frustum
	* @param bottom - Bottom bound of the frustum
	* @param top - Top bound of the frustum
	* @param near - Near bound of the frustum
	* @param far - Far bound of the frustum
	* @returns `this`
	*/
	orthoZO(left, right, bottom, top, near, far) {
		return Mat4.orthoZO(this, left, right, bottom, top, near, far);
	}
	/**
	* Creates a new, identity {@link Mat4}
	* @category Static
	*
	* @returns A new {@link Mat4}
	*/
	static create() {
		return new Mat4();
	}
	/**
	* Creates a new {@link Mat4} initialized with values from an existing matrix
	* @category Static
	*
	* @param a - Matrix to clone
	* @returns A new {@link Mat4}
	*/
	static clone(a) {
		return new Mat4(a);
	}
	/**
	* Copy the values from one {@link Mat4} to another
	* @category Static
	*
	* @param out - The receiving Matrix
	* @param a - Matrix to copy
	* @returns `out`
	*/
	static copy(out, a) {
		out[0] = a[0];
		out[1] = a[1];
		out[2] = a[2];
		out[3] = a[3];
		out[4] = a[4];
		out[5] = a[5];
		out[6] = a[6];
		out[7] = a[7];
		out[8] = a[8];
		out[9] = a[9];
		out[10] = a[10];
		out[11] = a[11];
		out[12] = a[12];
		out[13] = a[13];
		out[14] = a[14];
		out[15] = a[15];
		return out;
	}
	/**
	* Create a new mat4 with the given values
	* @category Static
	*
	* @param values - Matrix components
	* @returns A new {@link Mat4}
	*/
	static fromValues(...values) {
		return new Mat4(...values);
	}
	/**
	* Set the components of a mat4 to the given values
	* @category Static
	*
	* @param out - The receiving matrix
	* @param values - Matrix components
	* @returns `out`
	*/
	static set(out, ...values) {
		out[0] = values[0];
		out[1] = values[1];
		out[2] = values[2];
		out[3] = values[3];
		out[4] = values[4];
		out[5] = values[5];
		out[6] = values[6];
		out[7] = values[7];
		out[8] = values[8];
		out[9] = values[9];
		out[10] = values[10];
		out[11] = values[11];
		out[12] = values[12];
		out[13] = values[13];
		out[14] = values[14];
		out[15] = values[15];
		return out;
	}
	/**
	* Set a {@link Mat4} to the identity matrix
	* @category Static
	*
	* @param out - The receiving Matrix
	* @returns `out`
	*/
	static identity(out) {
		out[0] = 1;
		out[1] = 0;
		out[2] = 0;
		out[3] = 0;
		out[4] = 0;
		out[5] = 1;
		out[6] = 0;
		out[7] = 0;
		out[8] = 0;
		out[9] = 0;
		out[10] = 1;
		out[11] = 0;
		out[12] = 0;
		out[13] = 0;
		out[14] = 0;
		out[15] = 1;
		return out;
	}
	/**
	* Transpose the values of a {@link Mat4}
	* @category Static
	*
	* @param out - the receiving matrix
	* @param a - the source matrix
	* @returns `out`
	*/
	static transpose(out, a) {
		if (out === a) {
			const a01 = a[1], a02 = a[2], a03 = a[3];
			const a12 = a[6], a13 = a[7];
			const a23 = a[11];
			out[1] = a[4];
			out[2] = a[8];
			out[3] = a[12];
			out[4] = a01;
			out[6] = a[9];
			out[7] = a[13];
			out[8] = a02;
			out[9] = a12;
			out[11] = a[14];
			out[12] = a03;
			out[13] = a13;
			out[14] = a23;
		} else {
			out[0] = a[0];
			out[1] = a[4];
			out[2] = a[8];
			out[3] = a[12];
			out[4] = a[1];
			out[5] = a[5];
			out[6] = a[9];
			out[7] = a[13];
			out[8] = a[2];
			out[9] = a[6];
			out[10] = a[10];
			out[11] = a[14];
			out[12] = a[3];
			out[13] = a[7];
			out[14] = a[11];
			out[15] = a[15];
		}
		return out;
	}
	/**
	* Inverts a {@link Mat4}
	* @category Static
	*
	* @param out - the receiving matrix
	* @param a - the source matrix
	* @returns `out` or `null` if the matrix is not invertable
	*/
	static invert(out, a) {
		const a00 = a[0], a01 = a[1], a02 = a[2], a03 = a[3];
		const a10 = a[4], a11 = a[5], a12 = a[6], a13 = a[7];
		const a20 = a[8], a21 = a[9], a22 = a[10], a23 = a[11];
		const a30 = a[12], a31 = a[13], a32 = a[14], a33 = a[15];
		const b00 = a00 * a11 - a01 * a10;
		const b01 = a00 * a12 - a02 * a10;
		const b02 = a00 * a13 - a03 * a10;
		const b03 = a01 * a12 - a02 * a11;
		const b04 = a01 * a13 - a03 * a11;
		const b05 = a02 * a13 - a03 * a12;
		const b06 = a20 * a31 - a21 * a30;
		const b07 = a20 * a32 - a22 * a30;
		const b08 = a20 * a33 - a23 * a30;
		const b09 = a21 * a32 - a22 * a31;
		const b10 = a21 * a33 - a23 * a31;
		const b11 = a22 * a33 - a23 * a32;
		let det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
		if (!det) return null;
		det = 1 / det;
		out[0] = (a11 * b11 - a12 * b10 + a13 * b09) * det;
		out[1] = (a02 * b10 - a01 * b11 - a03 * b09) * det;
		out[2] = (a31 * b05 - a32 * b04 + a33 * b03) * det;
		out[3] = (a22 * b04 - a21 * b05 - a23 * b03) * det;
		out[4] = (a12 * b08 - a10 * b11 - a13 * b07) * det;
		out[5] = (a00 * b11 - a02 * b08 + a03 * b07) * det;
		out[6] = (a32 * b02 - a30 * b05 - a33 * b01) * det;
		out[7] = (a20 * b05 - a22 * b02 + a23 * b01) * det;
		out[8] = (a10 * b10 - a11 * b08 + a13 * b06) * det;
		out[9] = (a01 * b08 - a00 * b10 - a03 * b06) * det;
		out[10] = (a30 * b04 - a31 * b02 + a33 * b00) * det;
		out[11] = (a21 * b02 - a20 * b04 - a23 * b00) * det;
		out[12] = (a11 * b07 - a10 * b09 - a12 * b06) * det;
		out[13] = (a00 * b09 - a01 * b07 + a02 * b06) * det;
		out[14] = (a31 * b01 - a30 * b03 - a32 * b00) * det;
		out[15] = (a20 * b03 - a21 * b01 + a22 * b00) * det;
		return out;
	}
	/**
	* Calculates the adjugate of a {@link Mat4}
	* @category Static
	*
	* @param out - the receiving matrix
	* @param a - the source matrix
	* @returns `out`
	*/
	static adjoint(out, a) {
		const a00 = a[0], a01 = a[1], a02 = a[2], a03 = a[3];
		const a10 = a[4], a11 = a[5], a12 = a[6], a13 = a[7];
		const a20 = a[8], a21 = a[9], a22 = a[10], a23 = a[11];
		const a30 = a[12], a31 = a[13], a32 = a[14], a33 = a[15];
		const b00 = a00 * a11 - a01 * a10;
		const b01 = a00 * a12 - a02 * a10;
		const b02 = a00 * a13 - a03 * a10;
		const b03 = a01 * a12 - a02 * a11;
		const b04 = a01 * a13 - a03 * a11;
		const b05 = a02 * a13 - a03 * a12;
		const b06 = a20 * a31 - a21 * a30;
		const b07 = a20 * a32 - a22 * a30;
		const b08 = a20 * a33 - a23 * a30;
		const b09 = a21 * a32 - a22 * a31;
		const b10 = a21 * a33 - a23 * a31;
		const b11 = a22 * a33 - a23 * a32;
		out[0] = a11 * b11 - a12 * b10 + a13 * b09;
		out[1] = a02 * b10 - a01 * b11 - a03 * b09;
		out[2] = a31 * b05 - a32 * b04 + a33 * b03;
		out[3] = a22 * b04 - a21 * b05 - a23 * b03;
		out[4] = a12 * b08 - a10 * b11 - a13 * b07;
		out[5] = a00 * b11 - a02 * b08 + a03 * b07;
		out[6] = a32 * b02 - a30 * b05 - a33 * b01;
		out[7] = a20 * b05 - a22 * b02 + a23 * b01;
		out[8] = a10 * b10 - a11 * b08 + a13 * b06;
		out[9] = a01 * b08 - a00 * b10 - a03 * b06;
		out[10] = a30 * b04 - a31 * b02 + a33 * b00;
		out[11] = a21 * b02 - a20 * b04 - a23 * b00;
		out[12] = a11 * b07 - a10 * b09 - a12 * b06;
		out[13] = a00 * b09 - a01 * b07 + a02 * b06;
		out[14] = a31 * b01 - a30 * b03 - a32 * b00;
		out[15] = a20 * b03 - a21 * b01 + a22 * b00;
		return out;
	}
	/**
	* Calculates the determinant of a {@link Mat4}
	* @category Static
	*
	* @param a - the source matrix
	* @returns determinant of a
	*/
	static determinant(a) {
		const a00 = a[0], a01 = a[1], a02 = a[2], a03 = a[3];
		const a10 = a[4], a11 = a[5], a12 = a[6], a13 = a[7];
		const a20 = a[8], a21 = a[9], a22 = a[10], a23 = a[11];
		const a30 = a[12], a31 = a[13], a32 = a[14], a33 = a[15];
		const b0 = a00 * a11 - a01 * a10;
		const b1 = a00 * a12 - a02 * a10;
		const b2 = a01 * a12 - a02 * a11;
		const b3 = a20 * a31 - a21 * a30;
		const b4 = a20 * a32 - a22 * a30;
		const b5 = a21 * a32 - a22 * a31;
		const b6 = a00 * b5 - a01 * b4 + a02 * b3;
		const b7 = a10 * b5 - a11 * b4 + a12 * b3;
		const b8 = a20 * b2 - a21 * b1 + a22 * b0;
		const b9 = a30 * b2 - a31 * b1 + a32 * b0;
		return a13 * b6 - a03 * b7 + a33 * b8 - a23 * b9;
	}
	/**
	* Multiplies two {@link Mat4}s
	* @category Static
	*
	* @param out - The receiving Matrix
	* @param a - The first operand
	* @param b - The second operand
	* @returns `out`
	*/
	static multiply(out, a, b) {
		const a00 = a[0];
		const a01 = a[1];
		const a02 = a[2];
		const a03 = a[3];
		const a10 = a[4];
		const a11 = a[5];
		const a12 = a[6];
		const a13 = a[7];
		const a20 = a[8];
		const a21 = a[9];
		const a22 = a[10];
		const a23 = a[11];
		const a30 = a[12];
		const a31 = a[13];
		const a32 = a[14];
		const a33 = a[15];
		let b0 = b[0];
		let b1 = b[1];
		let b2 = b[2];
		let b3 = b[3];
		out[0] = b0 * a00 + b1 * a10 + b2 * a20 + b3 * a30;
		out[1] = b0 * a01 + b1 * a11 + b2 * a21 + b3 * a31;
		out[2] = b0 * a02 + b1 * a12 + b2 * a22 + b3 * a32;
		out[3] = b0 * a03 + b1 * a13 + b2 * a23 + b3 * a33;
		b0 = b[4];
		b1 = b[5];
		b2 = b[6];
		b3 = b[7];
		out[4] = b0 * a00 + b1 * a10 + b2 * a20 + b3 * a30;
		out[5] = b0 * a01 + b1 * a11 + b2 * a21 + b3 * a31;
		out[6] = b0 * a02 + b1 * a12 + b2 * a22 + b3 * a32;
		out[7] = b0 * a03 + b1 * a13 + b2 * a23 + b3 * a33;
		b0 = b[8];
		b1 = b[9];
		b2 = b[10];
		b3 = b[11];
		out[8] = b0 * a00 + b1 * a10 + b2 * a20 + b3 * a30;
		out[9] = b0 * a01 + b1 * a11 + b2 * a21 + b3 * a31;
		out[10] = b0 * a02 + b1 * a12 + b2 * a22 + b3 * a32;
		out[11] = b0 * a03 + b1 * a13 + b2 * a23 + b3 * a33;
		b0 = b[12];
		b1 = b[13];
		b2 = b[14];
		b3 = b[15];
		out[12] = b0 * a00 + b1 * a10 + b2 * a20 + b3 * a30;
		out[13] = b0 * a01 + b1 * a11 + b2 * a21 + b3 * a31;
		out[14] = b0 * a02 + b1 * a12 + b2 * a22 + b3 * a32;
		out[15] = b0 * a03 + b1 * a13 + b2 * a23 + b3 * a33;
		return out;
	}
	/**
	* Alias for {@link Mat4.multiply}
	* @category Static
	*/
	static mul(out, a, b) {
		return out;
	}
	/**
	* Translate a {@link Mat4} by the given vector
	* @category Static
	*
	* @param out - the receiving matrix
	* @param a - the matrix to translate
	* @param v - vector to translate by
	* @returns `out`
	*/
	static translate(out, a, v) {
		const x = v[0];
		const y = v[1];
		const z = v[2];
		if (a === out) {
			out[12] = a[0] * x + a[4] * y + a[8] * z + a[12];
			out[13] = a[1] * x + a[5] * y + a[9] * z + a[13];
			out[14] = a[2] * x + a[6] * y + a[10] * z + a[14];
			out[15] = a[3] * x + a[7] * y + a[11] * z + a[15];
		} else {
			const a00 = a[0];
			const a01 = a[1];
			const a02 = a[2];
			const a03 = a[3];
			const a10 = a[4];
			const a11 = a[5];
			const a12 = a[6];
			const a13 = a[7];
			const a20 = a[8];
			const a21 = a[9];
			const a22 = a[10];
			const a23 = a[11];
			out[0] = a00;
			out[1] = a01;
			out[2] = a02;
			out[3] = a03;
			out[4] = a10;
			out[5] = a11;
			out[6] = a12;
			out[7] = a13;
			out[8] = a20;
			out[9] = a21;
			out[10] = a22;
			out[11] = a23;
			out[12] = a00 * x + a10 * y + a20 * z + a[12];
			out[13] = a01 * x + a11 * y + a21 * z + a[13];
			out[14] = a02 * x + a12 * y + a22 * z + a[14];
			out[15] = a03 * x + a13 * y + a23 * z + a[15];
		}
		return out;
	}
	/**
	* Scales the {@link Mat4} by the dimensions in the given {@link Vec3} not using vectorization
	* @category Static
	*
	* @param out - the receiving matrix
	* @param a - the matrix to scale
	* @param v - the {@link Vec3} to scale the matrix by
	* @returns `out`
	**/
	static scale(out, a, v) {
		const x = v[0];
		const y = v[1];
		const z = v[2];
		out[0] = a[0] * x;
		out[1] = a[1] * x;
		out[2] = a[2] * x;
		out[3] = a[3] * x;
		out[4] = a[4] * y;
		out[5] = a[5] * y;
		out[6] = a[6] * y;
		out[7] = a[7] * y;
		out[8] = a[8] * z;
		out[9] = a[9] * z;
		out[10] = a[10] * z;
		out[11] = a[11] * z;
		out[12] = a[12];
		out[13] = a[13];
		out[14] = a[14];
		out[15] = a[15];
		return out;
	}
	/**
	* Rotates a {@link Mat4} by the given angle around the given axis
	* @category Static
	*
	* @param out - the receiving matrix
	* @param a - the matrix to rotate
	* @param rad - the angle to rotate the matrix by
	* @param axis - the axis to rotate around
	* @returns `out` or `null` if axis has a length of 0
	*/
	static rotate(out, a, rad, axis) {
		let x = axis[0];
		let y = axis[1];
		let z = axis[2];
		let len = Math.sqrt(x * x + y * y + z * z);
		if (len < 1e-6) return null;
		len = 1 / len;
		x *= len;
		y *= len;
		z *= len;
		const s = Math.sin(rad);
		const c = Math.cos(rad);
		const t = 1 - c;
		const a00 = a[0];
		const a01 = a[1];
		const a02 = a[2];
		const a03 = a[3];
		const a10 = a[4];
		const a11 = a[5];
		const a12 = a[6];
		const a13 = a[7];
		const a20 = a[8];
		const a21 = a[9];
		const a22 = a[10];
		const a23 = a[11];
		const b00 = x * x * t + c;
		const b01 = y * x * t + z * s;
		const b02 = z * x * t - y * s;
		const b10 = x * y * t - z * s;
		const b11 = y * y * t + c;
		const b12 = z * y * t + x * s;
		const b20 = x * z * t + y * s;
		const b21 = y * z * t - x * s;
		const b22 = z * z * t + c;
		out[0] = a00 * b00 + a10 * b01 + a20 * b02;
		out[1] = a01 * b00 + a11 * b01 + a21 * b02;
		out[2] = a02 * b00 + a12 * b01 + a22 * b02;
		out[3] = a03 * b00 + a13 * b01 + a23 * b02;
		out[4] = a00 * b10 + a10 * b11 + a20 * b12;
		out[5] = a01 * b10 + a11 * b11 + a21 * b12;
		out[6] = a02 * b10 + a12 * b11 + a22 * b12;
		out[7] = a03 * b10 + a13 * b11 + a23 * b12;
		out[8] = a00 * b20 + a10 * b21 + a20 * b22;
		out[9] = a01 * b20 + a11 * b21 + a21 * b22;
		out[10] = a02 * b20 + a12 * b21 + a22 * b22;
		out[11] = a03 * b20 + a13 * b21 + a23 * b22;
		if (a !== out) {
			out[12] = a[12];
			out[13] = a[13];
			out[14] = a[14];
			out[15] = a[15];
		}
		return out;
	}
	/**
	* Rotates a matrix by the given angle around the X axis
	* @category Static
	*
	* @param out - the receiving matrix
	* @param a - the matrix to rotate
	* @param rad - the angle to rotate the matrix by
	* @returns `out`
	*/
	static rotateX(out, a, rad) {
		let s = Math.sin(rad);
		let c = Math.cos(rad);
		let a10 = a[4];
		let a11 = a[5];
		let a12 = a[6];
		let a13 = a[7];
		let a20 = a[8];
		let a21 = a[9];
		let a22 = a[10];
		let a23 = a[11];
		if (a !== out) {
			out[0] = a[0];
			out[1] = a[1];
			out[2] = a[2];
			out[3] = a[3];
			out[12] = a[12];
			out[13] = a[13];
			out[14] = a[14];
			out[15] = a[15];
		}
		out[4] = a10 * c + a20 * s;
		out[5] = a11 * c + a21 * s;
		out[6] = a12 * c + a22 * s;
		out[7] = a13 * c + a23 * s;
		out[8] = a20 * c - a10 * s;
		out[9] = a21 * c - a11 * s;
		out[10] = a22 * c - a12 * s;
		out[11] = a23 * c - a13 * s;
		return out;
	}
	/**
	* Rotates a matrix by the given angle around the Y axis
	* @category Static
	*
	* @param out - the receiving matrix
	* @param a - the matrix to rotate
	* @param rad - the angle to rotate the matrix by
	* @returns `out`
	*/
	static rotateY(out, a, rad) {
		let s = Math.sin(rad);
		let c = Math.cos(rad);
		let a00 = a[0];
		let a01 = a[1];
		let a02 = a[2];
		let a03 = a[3];
		let a20 = a[8];
		let a21 = a[9];
		let a22 = a[10];
		let a23 = a[11];
		if (a !== out) {
			out[4] = a[4];
			out[5] = a[5];
			out[6] = a[6];
			out[7] = a[7];
			out[12] = a[12];
			out[13] = a[13];
			out[14] = a[14];
			out[15] = a[15];
		}
		out[0] = a00 * c - a20 * s;
		out[1] = a01 * c - a21 * s;
		out[2] = a02 * c - a22 * s;
		out[3] = a03 * c - a23 * s;
		out[8] = a00 * s + a20 * c;
		out[9] = a01 * s + a21 * c;
		out[10] = a02 * s + a22 * c;
		out[11] = a03 * s + a23 * c;
		return out;
	}
	/**
	* Rotates a matrix by the given angle around the Z axis
	* @category Static
	*
	* @param out - the receiving matrix
	* @param a - the matrix to rotate
	* @param rad - the angle to rotate the matrix by
	* @returns `out`
	*/
	static rotateZ(out, a, rad) {
		let s = Math.sin(rad);
		let c = Math.cos(rad);
		let a00 = a[0];
		let a01 = a[1];
		let a02 = a[2];
		let a03 = a[3];
		let a10 = a[4];
		let a11 = a[5];
		let a12 = a[6];
		let a13 = a[7];
		if (a !== out) {
			out[8] = a[8];
			out[9] = a[9];
			out[10] = a[10];
			out[11] = a[11];
			out[12] = a[12];
			out[13] = a[13];
			out[14] = a[14];
			out[15] = a[15];
		}
		out[0] = a00 * c + a10 * s;
		out[1] = a01 * c + a11 * s;
		out[2] = a02 * c + a12 * s;
		out[3] = a03 * c + a13 * s;
		out[4] = a10 * c - a00 * s;
		out[5] = a11 * c - a01 * s;
		out[6] = a12 * c - a02 * s;
		out[7] = a13 * c - a03 * s;
		return out;
	}
	/**
	* Creates a {@link Mat4} from a vector translation
	* This is equivalent to (but much faster than):
	*
	*     mat4.identity(dest);
	*     mat4.translate(dest, dest, vec);
	* @category Static
	*
	* @param out - {@link Mat4} receiving operation result
	* @param v - Translation vector
	* @returns `out`
	*/
	static fromTranslation(out, v) {
		out[0] = 1;
		out[1] = 0;
		out[2] = 0;
		out[3] = 0;
		out[4] = 0;
		out[5] = 1;
		out[6] = 0;
		out[7] = 0;
		out[8] = 0;
		out[9] = 0;
		out[10] = 1;
		out[11] = 0;
		out[12] = v[0];
		out[13] = v[1];
		out[14] = v[2];
		out[15] = 1;
		return out;
	}
	/**
	* Creates a {@link Mat4} from a vector scaling
	* This is equivalent to (but much faster than):
	*
	*     mat4.identity(dest);
	*     mat4.scale(dest, dest, vec);
	* @category Static
	*
	* @param out - {@link Mat4} receiving operation result
	* @param v - Scaling vector
	* @returns `out`
	*/
	static fromScaling(out, v) {
		out[0] = v[0];
		out[1] = 0;
		out[2] = 0;
		out[3] = 0;
		out[4] = 0;
		out[5] = v[1];
		out[6] = 0;
		out[7] = 0;
		out[8] = 0;
		out[9] = 0;
		out[10] = v[2];
		out[11] = 0;
		out[12] = 0;
		out[13] = 0;
		out[14] = 0;
		out[15] = 1;
		return out;
	}
	/**
	* Creates a {@link Mat4} from a given angle around a given axis
	* This is equivalent to (but much faster than):
	*
	*     mat4.identity(dest);
	*     mat4.rotate(dest, dest, rad, axis);
	* @category Static
	*
	* @param out - {@link Mat4} receiving operation result
	* @param rad - the angle to rotate the matrix by
	* @param axis - the axis to rotate around
	* @returns `out` or `null` if `axis` has a length of 0
	*/
	static fromRotation(out, rad, axis) {
		let x = axis[0];
		let y = axis[1];
		let z = axis[2];
		let len = Math.sqrt(x * x + y * y + z * z);
		if (len < 1e-6) return null;
		len = 1 / len;
		x *= len;
		y *= len;
		z *= len;
		const s = Math.sin(rad);
		const c = Math.cos(rad);
		const t = 1 - c;
		out[0] = x * x * t + c;
		out[1] = y * x * t + z * s;
		out[2] = z * x * t - y * s;
		out[3] = 0;
		out[4] = x * y * t - z * s;
		out[5] = y * y * t + c;
		out[6] = z * y * t + x * s;
		out[7] = 0;
		out[8] = x * z * t + y * s;
		out[9] = y * z * t - x * s;
		out[10] = z * z * t + c;
		out[11] = 0;
		out[12] = 0;
		out[13] = 0;
		out[14] = 0;
		out[15] = 1;
		return out;
	}
	/**
	* Creates a matrix from the given angle around the X axis
	* This is equivalent to (but much faster than):
	*
	*     mat4.identity(dest);
	*     mat4.rotateX(dest, dest, rad);
	* @category Static
	*
	* @param out - mat4 receiving operation result
	* @param rad - the angle to rotate the matrix by
	* @returns `out`
	*/
	static fromXRotation(out, rad) {
		let s = Math.sin(rad);
		let c = Math.cos(rad);
		out[0] = 1;
		out[1] = 0;
		out[2] = 0;
		out[3] = 0;
		out[4] = 0;
		out[5] = c;
		out[6] = s;
		out[7] = 0;
		out[8] = 0;
		out[9] = -s;
		out[10] = c;
		out[11] = 0;
		out[12] = 0;
		out[13] = 0;
		out[14] = 0;
		out[15] = 1;
		return out;
	}
	/**
	* Creates a matrix from the given angle around the Y axis
	* This is equivalent to (but much faster than):
	*
	*     mat4.identity(dest);
	*     mat4.rotateY(dest, dest, rad);
	* @category Static
	*
	* @param out - mat4 receiving operation result
	* @param rad - the angle to rotate the matrix by
	* @returns `out`
	*/
	static fromYRotation(out, rad) {
		let s = Math.sin(rad);
		let c = Math.cos(rad);
		out[0] = c;
		out[1] = 0;
		out[2] = -s;
		out[3] = 0;
		out[4] = 0;
		out[5] = 1;
		out[6] = 0;
		out[7] = 0;
		out[8] = s;
		out[9] = 0;
		out[10] = c;
		out[11] = 0;
		out[12] = 0;
		out[13] = 0;
		out[14] = 0;
		out[15] = 1;
		return out;
	}
	/**
	* Creates a matrix from the given angle around the Z axis
	* This is equivalent to (but much faster than):
	*
	*     mat4.identity(dest);
	*     mat4.rotateZ(dest, dest, rad);
	* @category Static
	*
	* @param out - mat4 receiving operation result
	* @param rad - the angle to rotate the matrix by
	* @returns `out`
	*/
	static fromZRotation(out, rad) {
		const s = Math.sin(rad);
		const c = Math.cos(rad);
		out[0] = c;
		out[1] = s;
		out[2] = 0;
		out[3] = 0;
		out[4] = -s;
		out[5] = c;
		out[6] = 0;
		out[7] = 0;
		out[8] = 0;
		out[9] = 0;
		out[10] = 1;
		out[11] = 0;
		out[12] = 0;
		out[13] = 0;
		out[14] = 0;
		out[15] = 1;
		return out;
	}
	/**
	* Creates a matrix from a quaternion rotation and vector translation
	* This is equivalent to (but much faster than):
	*
	*     mat4.identity(dest);
	*     mat4.translate(dest, vec);
	*     let quatMat = mat4.create();
	*     quat4.toMat4(quat, quatMat);
	*     mat4.multiply(dest, quatMat);
	* @category Static
	*
	* @param out - mat4 receiving operation result
	* @param q - Rotation quaternion
	* @param v - Translation vector
	* @returns `out`
	*/
	static fromRotationTranslation(out, q, v) {
		const x = q[0];
		const y = q[1];
		const z = q[2];
		const w = q[3];
		const x2 = x + x;
		const y2 = y + y;
		const z2 = z + z;
		const xx = x * x2;
		const xy = x * y2;
		const xz = x * z2;
		const yy = y * y2;
		const yz = y * z2;
		const zz = z * z2;
		const wx = w * x2;
		const wy = w * y2;
		const wz = w * z2;
		out[0] = 1 - (yy + zz);
		out[1] = xy + wz;
		out[2] = xz - wy;
		out[3] = 0;
		out[4] = xy - wz;
		out[5] = 1 - (xx + zz);
		out[6] = yz + wx;
		out[7] = 0;
		out[8] = xz + wy;
		out[9] = yz - wx;
		out[10] = 1 - (xx + yy);
		out[11] = 0;
		out[12] = v[0];
		out[13] = v[1];
		out[14] = v[2];
		out[15] = 1;
		return out;
	}
	/**
	* Sets a {@link Mat4} from a {@link Quat2}.
	* @category Static
	*
	* @param out - Matrix
	* @param a - Dual Quaternion
	* @returns `out`
	*/
	static fromQuat2(out, a) {
		const bx = -a[0];
		const by = -a[1];
		const bz = -a[2];
		const bw = a[3];
		const ax = a[4];
		const ay = a[5];
		const az = a[6];
		const aw = a[7];
		let magnitude = bx * bx + by * by + bz * bz + bw * bw;
		if (magnitude > 0) {
			tmpVec3[0] = (ax * bw + aw * bx + ay * bz - az * by) * 2 / magnitude;
			tmpVec3[1] = (ay * bw + aw * by + az * bx - ax * bz) * 2 / magnitude;
			tmpVec3[2] = (az * bw + aw * bz + ax * by - ay * bx) * 2 / magnitude;
		} else {
			tmpVec3[0] = (ax * bw + aw * bx + ay * bz - az * by) * 2;
			tmpVec3[1] = (ay * bw + aw * by + az * bx - ax * bz) * 2;
			tmpVec3[2] = (az * bw + aw * bz + ax * by - ay * bx) * 2;
		}
		Mat4.fromRotationTranslation(out, a, tmpVec3);
		return out;
	}
	/**
	* Calculates a {@link Mat4} normal matrix (transpose inverse) from a {@link Mat4}
	* @category Static
	*
	* @param out - Matrix receiving operation result
	* @param a - Mat4 to derive the normal matrix from
	* @returns `out` or `null` if the matrix is not invertable
	*/
	static normalFromMat4(out, a) {
		const a00 = a[0];
		const a01 = a[1];
		const a02 = a[2];
		const a03 = a[3];
		const a10 = a[4];
		const a11 = a[5];
		const a12 = a[6];
		const a13 = a[7];
		const a20 = a[8];
		const a21 = a[9];
		const a22 = a[10];
		const a23 = a[11];
		const a30 = a[12];
		const a31 = a[13];
		const a32 = a[14];
		const a33 = a[15];
		const b00 = a00 * a11 - a01 * a10;
		const b01 = a00 * a12 - a02 * a10;
		const b02 = a00 * a13 - a03 * a10;
		const b03 = a01 * a12 - a02 * a11;
		const b04 = a01 * a13 - a03 * a11;
		const b05 = a02 * a13 - a03 * a12;
		const b06 = a20 * a31 - a21 * a30;
		const b07 = a20 * a32 - a22 * a30;
		const b08 = a20 * a33 - a23 * a30;
		const b09 = a21 * a32 - a22 * a31;
		const b10 = a21 * a33 - a23 * a31;
		const b11 = a22 * a33 - a23 * a32;
		let det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
		if (!det) return null;
		det = 1 / det;
		out[0] = (a11 * b11 - a12 * b10 + a13 * b09) * det;
		out[1] = (a12 * b08 - a10 * b11 - a13 * b07) * det;
		out[2] = (a10 * b10 - a11 * b08 + a13 * b06) * det;
		out[3] = 0;
		out[4] = (a02 * b10 - a01 * b11 - a03 * b09) * det;
		out[5] = (a00 * b11 - a02 * b08 + a03 * b07) * det;
		out[6] = (a01 * b08 - a00 * b10 - a03 * b06) * det;
		out[7] = 0;
		out[8] = (a31 * b05 - a32 * b04 + a33 * b03) * det;
		out[9] = (a32 * b02 - a30 * b05 - a33 * b01) * det;
		out[10] = (a30 * b04 - a31 * b02 + a33 * b00) * det;
		out[11] = 0;
		out[12] = 0;
		out[13] = 0;
		out[14] = 0;
		out[15] = 1;
		return out;
	}
	/**
	* Calculates a {@link Mat4} normal matrix (transpose inverse) from a {@link Mat4}
	* This version omits the calculation of the constant factor (1/determinant), so
	* any normals transformed with it will need to be renormalized.
	* From https://stackoverflow.com/a/27616419/25968
	* @category Static
	*
	* @param out - Matrix receiving operation result
	* @param a - Mat4 to derive the normal matrix from
	* @returns `out`
	*/
	static normalFromMat4Fast(out, a) {
		const ax = a[0];
		const ay = a[1];
		const az = a[2];
		const bx = a[4];
		const by = a[5];
		const bz = a[6];
		const cx = a[8];
		const cy = a[9];
		const cz = a[10];
		out[0] = by * cz - cz * cy;
		out[1] = bz * cx - cx * cz;
		out[2] = bx * cy - cy * cx;
		out[3] = 0;
		out[4] = cy * az - cz * ay;
		out[5] = cz * ax - cx * az;
		out[6] = cx * ay - cy * ax;
		out[7] = 0;
		out[8] = ay * bz - az * by;
		out[9] = az * bx - ax * bz;
		out[10] = ax * by - ay * bx;
		out[11] = 0;
		out[12] = 0;
		out[13] = 0;
		out[14] = 0;
		out[15] = 1;
		return out;
	}
	/**
	* Returns the translation vector component of a transformation
	* matrix. If a matrix is built with fromRotationTranslation,
	* the returned vector will be the same as the translation vector
	* originally supplied.
	* @category Static
	*
	* @param  {vec3} out Vector to receive translation component
	* @param  {ReadonlyMat4} mat Matrix to be decomposed (input)
	* @return {vec3} out
	*/
	static getTranslation(out, mat) {
		out[0] = mat[12];
		out[1] = mat[13];
		out[2] = mat[14];
		return out;
	}
	/**
	* Returns the scaling factor component of a transformation
	* matrix. If a matrix is built with fromRotationTranslationScale
	* with a normalized Quaternion parameter, the returned vector will be
	* the same as the scaling vector
	* originally supplied.
	* @category Static
	*
	* @param  {vec3} out Vector to receive scaling factor component
	* @param  {ReadonlyMat4} mat Matrix to be decomposed (input)
	* @return {vec3} out
	*/
	static getScaling(out, mat) {
		const m11 = mat[0];
		const m12 = mat[1];
		const m13 = mat[2];
		const m21 = mat[4];
		const m22 = mat[5];
		const m23 = mat[6];
		const m31 = mat[8];
		const m32 = mat[9];
		const m33 = mat[10];
		out[0] = Math.sqrt(m11 * m11 + m12 * m12 + m13 * m13);
		out[1] = Math.sqrt(m21 * m21 + m22 * m22 + m23 * m23);
		out[2] = Math.sqrt(m31 * m31 + m32 * m32 + m33 * m33);
		return out;
	}
	/**
	* Returns a quaternion representing the rotational component
	* of a transformation matrix. If a matrix is built with
	* fromRotationTranslation, the returned quaternion will be the
	* same as the quaternion originally supplied.
	* @category Static
	*
	* @param out - Quaternion to receive the rotation component
	* @param mat - Matrix to be decomposed (input)
	* @return `out`
	*/
	static getRotation(out, mat) {
		Mat4.getScaling(tmpVec3, mat);
		const is1 = 1 / tmpVec3[0];
		const is2 = 1 / tmpVec3[1];
		const is3 = 1 / tmpVec3[2];
		const sm11 = mat[0] * is1;
		const sm12 = mat[1] * is2;
		const sm13 = mat[2] * is3;
		const sm21 = mat[4] * is1;
		const sm22 = mat[5] * is2;
		const sm23 = mat[6] * is3;
		const sm31 = mat[8] * is1;
		const sm32 = mat[9] * is2;
		const sm33 = mat[10] * is3;
		const trace = sm11 + sm22 + sm33;
		let S = 0;
		if (trace > 0) {
			S = Math.sqrt(trace + 1) * 2;
			out[3] = .25 * S;
			out[0] = (sm23 - sm32) / S;
			out[1] = (sm31 - sm13) / S;
			out[2] = (sm12 - sm21) / S;
		} else if (sm11 > sm22 && sm11 > sm33) {
			S = Math.sqrt(1 + sm11 - sm22 - sm33) * 2;
			out[3] = (sm23 - sm32) / S;
			out[0] = .25 * S;
			out[1] = (sm12 + sm21) / S;
			out[2] = (sm31 + sm13) / S;
		} else if (sm22 > sm33) {
			S = Math.sqrt(1 + sm22 - sm11 - sm33) * 2;
			out[3] = (sm31 - sm13) / S;
			out[0] = (sm12 + sm21) / S;
			out[1] = .25 * S;
			out[2] = (sm23 + sm32) / S;
		} else {
			S = Math.sqrt(1 + sm33 - sm11 - sm22) * 2;
			out[3] = (sm12 - sm21) / S;
			out[0] = (sm31 + sm13) / S;
			out[1] = (sm23 + sm32) / S;
			out[2] = .25 * S;
		}
		return out;
	}
	/**
	* Decomposes a transformation matrix into its rotation, translation
	* and scale components. Returns only the rotation component
	* @category Static
	*
	* @param out_r - Quaternion to receive the rotation component
	* @param out_t - Vector to receive the translation vector
	* @param out_s - Vector to receive the scaling factor
	* @param mat - Matrix to be decomposed (input)
	* @returns `out_r`
	*/
	static decompose(out_r, out_t, out_s, mat) {
		out_t[0] = mat[12];
		out_t[1] = mat[13];
		out_t[2] = mat[14];
		const m11 = mat[0];
		const m12 = mat[1];
		const m13 = mat[2];
		const m21 = mat[4];
		const m22 = mat[5];
		const m23 = mat[6];
		const m31 = mat[8];
		const m32 = mat[9];
		const m33 = mat[10];
		out_s[0] = Math.sqrt(m11 * m11 + m12 * m12 + m13 * m13);
		out_s[1] = Math.sqrt(m21 * m21 + m22 * m22 + m23 * m23);
		out_s[2] = Math.sqrt(m31 * m31 + m32 * m32 + m33 * m33);
		const is1 = 1 / out_s[0];
		const is2 = 1 / out_s[1];
		const is3 = 1 / out_s[2];
		const sm11 = m11 * is1;
		const sm12 = m12 * is2;
		const sm13 = m13 * is3;
		const sm21 = m21 * is1;
		const sm22 = m22 * is2;
		const sm23 = m23 * is3;
		const sm31 = m31 * is1;
		const sm32 = m32 * is2;
		const sm33 = m33 * is3;
		const trace = sm11 + sm22 + sm33;
		let S = 0;
		if (trace > 0) {
			S = Math.sqrt(trace + 1) * 2;
			out_r[3] = .25 * S;
			out_r[0] = (sm23 - sm32) / S;
			out_r[1] = (sm31 - sm13) / S;
			out_r[2] = (sm12 - sm21) / S;
		} else if (sm11 > sm22 && sm11 > sm33) {
			S = Math.sqrt(1 + sm11 - sm22 - sm33) * 2;
			out_r[3] = (sm23 - sm32) / S;
			out_r[0] = .25 * S;
			out_r[1] = (sm12 + sm21) / S;
			out_r[2] = (sm31 + sm13) / S;
		} else if (sm22 > sm33) {
			S = Math.sqrt(1 + sm22 - sm11 - sm33) * 2;
			out_r[3] = (sm31 - sm13) / S;
			out_r[0] = (sm12 + sm21) / S;
			out_r[1] = .25 * S;
			out_r[2] = (sm23 + sm32) / S;
		} else {
			S = Math.sqrt(1 + sm33 - sm11 - sm22) * 2;
			out_r[3] = (sm12 - sm21) / S;
			out_r[0] = (sm31 + sm13) / S;
			out_r[1] = (sm23 + sm32) / S;
			out_r[2] = .25 * S;
		}
		return out_r;
	}
	/**
	* Creates a matrix from a quaternion rotation, vector translation and vector scale
	* This is equivalent to (but much faster than):
	*
	*     mat4.identity(dest);
	*     mat4.translate(dest, vec);
	*     let quatMat = mat4.create();
	*     quat4.toMat4(quat, quatMat);
	*     mat4.multiply(dest, quatMat);
	*     mat4.scale(dest, scale);
	* @category Static
	*
	* @param out - mat4 receiving operation result
	* @param q - Rotation quaternion
	* @param v - Translation vector
	* @param s - Scaling vector
	* @returns `out`
	*/
	static fromRotationTranslationScale(out, q, v, s) {
		const x = q[0];
		const y = q[1];
		const z = q[2];
		const w = q[3];
		const x2 = x + x;
		const y2 = y + y;
		const z2 = z + z;
		const xx = x * x2;
		const xy = x * y2;
		const xz = x * z2;
		const yy = y * y2;
		const yz = y * z2;
		const zz = z * z2;
		const wx = w * x2;
		const wy = w * y2;
		const wz = w * z2;
		const sx = s[0];
		const sy = s[1];
		const sz = s[2];
		out[0] = (1 - (yy + zz)) * sx;
		out[1] = (xy + wz) * sx;
		out[2] = (xz - wy) * sx;
		out[3] = 0;
		out[4] = (xy - wz) * sy;
		out[5] = (1 - (xx + zz)) * sy;
		out[6] = (yz + wx) * sy;
		out[7] = 0;
		out[8] = (xz + wy) * sz;
		out[9] = (yz - wx) * sz;
		out[10] = (1 - (xx + yy)) * sz;
		out[11] = 0;
		out[12] = v[0];
		out[13] = v[1];
		out[14] = v[2];
		out[15] = 1;
		return out;
	}
	/**
	* Creates a matrix from a quaternion rotation, vector translation and vector scale, rotating and scaling around the given origin
	* This is equivalent to (but much faster than):
	*
	*     mat4.identity(dest);
	*     mat4.translate(dest, vec);
	*     mat4.translate(dest, origin);
	*     let quatMat = mat4.create();
	*     quat4.toMat4(quat, quatMat);
	*     mat4.multiply(dest, quatMat);
	*     mat4.scale(dest, scale)
	*     mat4.translate(dest, negativeOrigin);
	* @category Static
	*
	* @param out - mat4 receiving operation result
	* @param q - Rotation quaternion
	* @param v - Translation vector
	* @param s - Scaling vector
	* @param o - The origin vector around which to scale and rotate
	* @returns `out`
	*/
	static fromRotationTranslationScaleOrigin(out, q, v, s, o) {
		const x = q[0];
		const y = q[1];
		const z = q[2];
		const w = q[3];
		const x2 = x + x;
		const y2 = y + y;
		const z2 = z + z;
		const xx = x * x2;
		const xy = x * y2;
		const xz = x * z2;
		const yy = y * y2;
		const yz = y * z2;
		const zz = z * z2;
		const wx = w * x2;
		const wy = w * y2;
		const wz = w * z2;
		const sx = s[0];
		const sy = s[1];
		const sz = s[2];
		const ox = o[0];
		const oy = o[1];
		const oz = o[2];
		const out0 = (1 - (yy + zz)) * sx;
		const out1 = (xy + wz) * sx;
		const out2 = (xz - wy) * sx;
		const out4 = (xy - wz) * sy;
		const out5 = (1 - (xx + zz)) * sy;
		const out6 = (yz + wx) * sy;
		const out8 = (xz + wy) * sz;
		const out9 = (yz - wx) * sz;
		const out10 = (1 - (xx + yy)) * sz;
		out[0] = out0;
		out[1] = out1;
		out[2] = out2;
		out[3] = 0;
		out[4] = out4;
		out[5] = out5;
		out[6] = out6;
		out[7] = 0;
		out[8] = out8;
		out[9] = out9;
		out[10] = out10;
		out[11] = 0;
		out[12] = v[0] + ox - (out0 * ox + out4 * oy + out8 * oz);
		out[13] = v[1] + oy - (out1 * ox + out5 * oy + out9 * oz);
		out[14] = v[2] + oz - (out2 * ox + out6 * oy + out10 * oz);
		out[15] = 1;
		return out;
	}
	/**
	* Calculates a 4x4 matrix from the given quaternion
	* @category Static
	*
	* @param out - mat4 receiving operation result
	* @param q - Quaternion to create matrix from
	* @returns `out`
	*/
	static fromQuat(out, q) {
		const x = q[0];
		const y = q[1];
		const z = q[2];
		const w = q[3];
		const x2 = x + x;
		const y2 = y + y;
		const z2 = z + z;
		const xx = x * x2;
		const yx = y * x2;
		const yy = y * y2;
		const zx = z * x2;
		const zy = z * y2;
		const zz = z * z2;
		const wx = w * x2;
		const wy = w * y2;
		const wz = w * z2;
		out[0] = 1 - yy - zz;
		out[1] = yx + wz;
		out[2] = zx - wy;
		out[3] = 0;
		out[4] = yx - wz;
		out[5] = 1 - xx - zz;
		out[6] = zy + wx;
		out[7] = 0;
		out[8] = zx + wy;
		out[9] = zy - wx;
		out[10] = 1 - xx - yy;
		out[11] = 0;
		out[12] = 0;
		out[13] = 0;
		out[14] = 0;
		out[15] = 1;
		return out;
	}
	/**
	* Generates a frustum matrix with the given bounds
	* The near/far clip planes correspond to a normalized device coordinate Z range of [-1, 1],
	* which matches WebGL/OpenGL's clip volume.
	* Passing null/undefined/no value for far will generate infinite projection matrix.
	* @category Static
	*
	* @param out - mat4 frustum matrix will be written into
	* @param left - Left bound of the frustum
	* @param right - Right bound of the frustum
	* @param bottom - Bottom bound of the frustum
	* @param top - Top bound of the frustum
	* @param near - Near bound of the frustum
	* @param far -  Far bound of the frustum, can be null or Infinity
	* @returns `out`
	*/
	static frustumNO(out, left, right, bottom, top, near, far = Infinity) {
		const rl = 1 / (right - left);
		const tb = 1 / (top - bottom);
		out[0] = near * 2 * rl;
		out[1] = 0;
		out[2] = 0;
		out[3] = 0;
		out[4] = 0;
		out[5] = near * 2 * tb;
		out[6] = 0;
		out[7] = 0;
		out[8] = (right + left) * rl;
		out[9] = (top + bottom) * tb;
		out[11] = -1;
		out[12] = 0;
		out[13] = 0;
		out[15] = 0;
		if (far != null && far !== Infinity) {
			const nf = 1 / (near - far);
			out[10] = (far + near) * nf;
			out[14] = 2 * far * near * nf;
		} else {
			out[10] = -1;
			out[14] = -2 * near;
		}
		return out;
	}
	/**
	* Alias for {@link Mat4.frustumNO}
	* @category Static
	* @deprecated Use {@link Mat4.frustumNO} or {@link Mat4.frustumZO} explicitly
	*/
	static frustum(out, left, right, bottom, top, near, far = Infinity) {
		return out;
	}
	/**
	* Generates a frustum matrix with the given bounds
	* The near/far clip planes correspond to a normalized device coordinate Z range of [0, 1],
	* which matches WebGPU/Vulkan/DirectX/Metal's clip volume.
	* Passing null/undefined/no value for far will generate infinite projection matrix.
	* @category Static
	*
	* @param out - mat4 frustum matrix will be written into
	* @param left - Left bound of the frustum
	* @param right - Right bound of the frustum
	* @param bottom - Bottom bound of the frustum
	* @param top - Top bound of the frustum
	* @param near - Near bound of the frustum
	* @param far - Far bound of the frustum, can be null or Infinity
	* @returns `out`
	*/
	static frustumZO(out, left, right, bottom, top, near, far = Infinity) {
		const rl = 1 / (right - left);
		const tb = 1 / (top - bottom);
		out[0] = near * 2 * rl;
		out[1] = 0;
		out[2] = 0;
		out[3] = 0;
		out[4] = 0;
		out[5] = near * 2 * tb;
		out[6] = 0;
		out[7] = 0;
		out[8] = (right + left) * rl;
		out[9] = (top + bottom) * tb;
		out[11] = -1;
		out[12] = 0;
		out[13] = 0;
		out[15] = 0;
		if (far != null && far !== Infinity) {
			const nf = 1 / (near - far);
			out[10] = far * nf;
			out[14] = far * near * nf;
		} else {
			out[10] = -1;
			out[14] = -near;
		}
		return out;
	}
	/**
	* Generates a perspective projection matrix with the given bounds.
	* The near/far clip planes correspond to a normalized device coordinate Z range of [-1, 1],
	* which matches WebGL/OpenGL's clip volume.
	* Passing null/undefined/no value for far will generate infinite projection matrix.
	* @category Static
	*
	* @param out - mat4 frustum matrix will be written into
	* @param fovy - Vertical field of view in radians
	* @param aspect - Aspect ratio. typically viewport width/height
	* @param near - Near bound of the frustum
	* @param far - Far bound of the frustum, can be null or Infinity
	* @returns `out`
	*/
	static perspectiveNO(out, fovy, aspect, near, far = Infinity) {
		const f = 1 / Math.tan(fovy / 2);
		out[0] = f / aspect;
		out[1] = 0;
		out[2] = 0;
		out[3] = 0;
		out[4] = 0;
		out[5] = f;
		out[6] = 0;
		out[7] = 0;
		out[8] = 0;
		out[9] = 0;
		out[11] = -1;
		out[12] = 0;
		out[13] = 0;
		out[15] = 0;
		if (far != null && far !== Infinity) {
			const nf = 1 / (near - far);
			out[10] = (far + near) * nf;
			out[14] = 2 * far * near * nf;
		} else {
			out[10] = -1;
			out[14] = -2 * near;
		}
		return out;
	}
	/**
	* Alias for {@link Mat4.perspectiveNO}
	* @category Static
	* @deprecated Use {@link Mat4.perspectiveNO} or {@link Mat4.perspectiveZO} explicitly
	*/
	static perspective(out, fovy, aspect, near, far = Infinity) {
		return out;
	}
	/**
	* Generates a perspective projection matrix suitable for WebGPU with the given bounds.
	* The near/far clip planes correspond to a normalized device coordinate Z range of [0, 1],
	* which matches WebGPU/Vulkan/DirectX/Metal's clip volume.
	* Passing null/undefined/no value for far will generate infinite projection matrix.
	* @category Static
	*
	* @param out - mat4 frustum matrix will be written into
	* @param fovy - Vertical field of view in radians
	* @param aspect - Aspect ratio. typically viewport width/height
	* @param near - Near bound of the frustum
	* @param far - Far bound of the frustum, can be null or Infinity
	* @returns `out`
	*/
	static perspectiveZO(out, fovy, aspect, near, far = Infinity) {
		const f = 1 / Math.tan(fovy / 2);
		out[0] = f / aspect;
		out[1] = 0;
		out[2] = 0;
		out[3] = 0;
		out[4] = 0;
		out[5] = f;
		out[6] = 0;
		out[7] = 0;
		out[8] = 0;
		out[9] = 0;
		out[11] = -1;
		out[12] = 0;
		out[13] = 0;
		out[15] = 0;
		if (far != null && far !== Infinity) {
			const nf = 1 / (near - far);
			out[10] = far * nf;
			out[14] = far * near * nf;
		} else {
			out[10] = -1;
			out[14] = -near;
		}
		return out;
	}
	/**
	* Generates a perspective projection matrix with the given field of view.
	* This is primarily useful for generating projection matrices to be used
	* with the still experiemental WebVR API.
	* @category Static
	*
	* @param out - mat4 frustum matrix will be written into
	* @param fov - Object containing the following values: upDegrees, downDegrees, leftDegrees, rightDegrees
	* @param near - Near bound of the frustum
	* @param far - Far bound of the frustum
	* @returns `out`
	* @deprecated
	*/
	static perspectiveFromFieldOfView(out, fov, near, far) {
		const upTan = Math.tan(fov.upDegrees * Math.PI / 180);
		const downTan = Math.tan(fov.downDegrees * Math.PI / 180);
		const leftTan = Math.tan(fov.leftDegrees * Math.PI / 180);
		const rightTan = Math.tan(fov.rightDegrees * Math.PI / 180);
		const xScale = 2 / (leftTan + rightTan);
		const yScale = 2 / (upTan + downTan);
		out[0] = xScale;
		out[1] = 0;
		out[2] = 0;
		out[3] = 0;
		out[4] = 0;
		out[5] = yScale;
		out[6] = 0;
		out[7] = 0;
		out[8] = -((leftTan - rightTan) * xScale * .5);
		out[9] = (upTan - downTan) * yScale * .5;
		out[10] = far / (near - far);
		out[11] = -1;
		out[12] = 0;
		out[13] = 0;
		out[14] = far * near / (near - far);
		out[15] = 0;
		return out;
	}
	/**
	* Generates a orthogonal projection matrix with the given bounds.
	* The near/far clip planes correspond to a normalized device coordinate Z range of [-1, 1],
	* which matches WebGL/OpenGL's clip volume.
	* @category Static
	*
	* @param out - mat4 frustum matrix will be written into
	* @param left - Left bound of the frustum
	* @param right - Right bound of the frustum
	* @param bottom - Bottom bound of the frustum
	* @param top - Top bound of the frustum
	* @param near - Near bound of the frustum
	* @param far - Far bound of the frustum
	* @returns `out`
	*/
	static orthoNO(out, left, right, bottom, top, near, far) {
		const lr = 1 / (left - right);
		const bt = 1 / (bottom - top);
		const nf = 1 / (near - far);
		out[0] = -2 * lr;
		out[1] = 0;
		out[2] = 0;
		out[3] = 0;
		out[4] = 0;
		out[5] = -2 * bt;
		out[6] = 0;
		out[7] = 0;
		out[8] = 0;
		out[9] = 0;
		out[10] = 2 * nf;
		out[11] = 0;
		out[12] = (left + right) * lr;
		out[13] = (top + bottom) * bt;
		out[14] = (far + near) * nf;
		out[15] = 1;
		return out;
	}
	/**
	* Alias for {@link Mat4.orthoNO}
	* @category Static
	* @deprecated Use {@link Mat4.orthoNO} or {@link Mat4.orthoZO} explicitly
	*/
	static ortho(out, left, right, bottom, top, near, far) {
		return out;
	}
	/**
	* Generates a orthogonal projection matrix with the given bounds.
	* The near/far clip planes correspond to a normalized device coordinate Z range of [0, 1],
	* which matches WebGPU/Vulkan/DirectX/Metal's clip volume.
	* @category Static
	*
	* @param out - mat4 frustum matrix will be written into
	* @param left - Left bound of the frustum
	* @param right - Right bound of the frustum
	* @param bottom - Bottom bound of the frustum
	* @param top - Top bound of the frustum
	* @param near - Near bound of the frustum
	* @param far - Far bound of the frustum
	* @returns `out`
	*/
	static orthoZO(out, left, right, bottom, top, near, far) {
		const lr = 1 / (left - right);
		const bt = 1 / (bottom - top);
		const nf = 1 / (near - far);
		out[0] = -2 * lr;
		out[1] = 0;
		out[2] = 0;
		out[3] = 0;
		out[4] = 0;
		out[5] = -2 * bt;
		out[6] = 0;
		out[7] = 0;
		out[8] = 0;
		out[9] = 0;
		out[10] = nf;
		out[11] = 0;
		out[12] = (left + right) * lr;
		out[13] = (top + bottom) * bt;
		out[14] = near * nf;
		out[15] = 1;
		return out;
	}
	/**
	* Generates a look-at matrix with the given eye position, focal point, and up axis.
	* If you want a matrix that actually makes an object look at another object, you should use targetTo instead.
	* @category Static
	*
	* @param out - mat4 frustum matrix will be written into
	* @param eye - Position of the viewer
	* @param center - Point the viewer is looking at
	* @param up - vec3 pointing up
	* @returns `out`
	*/
	static lookAt(out, eye, center, up) {
		const eyex = eye[0];
		const eyey = eye[1];
		const eyez = eye[2];
		const upx = up[0];
		const upy = up[1];
		const upz = up[2];
		const centerx = center[0];
		const centery = center[1];
		const centerz = center[2];
		if (Math.abs(eyex - centerx) < 1e-6 && Math.abs(eyey - centery) < 1e-6 && Math.abs(eyez - centerz) < 1e-6) return Mat4.identity(out);
		let z0 = eyex - centerx;
		let z1 = eyey - centery;
		let z2 = eyez - centerz;
		let len = 1 / Math.sqrt(z0 * z0 + z1 * z1 + z2 * z2);
		z0 *= len;
		z1 *= len;
		z2 *= len;
		let x0 = upy * z2 - upz * z1;
		let x1 = upz * z0 - upx * z2;
		let x2 = upx * z1 - upy * z0;
		len = Math.sqrt(x0 * x0 + x1 * x1 + x2 * x2);
		if (!len) {
			x0 = 0;
			x1 = 0;
			x2 = 0;
		} else {
			len = 1 / len;
			x0 *= len;
			x1 *= len;
			x2 *= len;
		}
		let y0 = z1 * x2 - z2 * x1;
		let y1 = z2 * x0 - z0 * x2;
		let y2 = z0 * x1 - z1 * x0;
		len = Math.sqrt(y0 * y0 + y1 * y1 + y2 * y2);
		if (!len) {
			y0 = 0;
			y1 = 0;
			y2 = 0;
		} else {
			len = 1 / len;
			y0 *= len;
			y1 *= len;
			y2 *= len;
		}
		out[0] = x0;
		out[1] = y0;
		out[2] = z0;
		out[3] = 0;
		out[4] = x1;
		out[5] = y1;
		out[6] = z1;
		out[7] = 0;
		out[8] = x2;
		out[9] = y2;
		out[10] = z2;
		out[11] = 0;
		out[12] = -(x0 * eyex + x1 * eyey + x2 * eyez);
		out[13] = -(y0 * eyex + y1 * eyey + y2 * eyez);
		out[14] = -(z0 * eyex + z1 * eyey + z2 * eyez);
		out[15] = 1;
		return out;
	}
	/**
	* Generates a matrix that makes something look at something else.
	* @category Static
	*
	* @param out - mat4 frustum matrix will be written into
	* @param eye - Position of the viewer
	* @param target - Point the viewer is looking at
	* @param up - vec3 pointing up
	* @returns `out`
	*/
	static targetTo(out, eye, target, up) {
		const eyex = eye[0];
		const eyey = eye[1];
		const eyez = eye[2];
		const upx = up[0];
		const upy = up[1];
		const upz = up[2];
		let z0 = eyex - target[0];
		let z1 = eyey - target[1];
		let z2 = eyez - target[2];
		let len = z0 * z0 + z1 * z1 + z2 * z2;
		if (len > 0) {
			len = 1 / Math.sqrt(len);
			z0 *= len;
			z1 *= len;
			z2 *= len;
		}
		let x0 = upy * z2 - upz * z1;
		let x1 = upz * z0 - upx * z2;
		let x2 = upx * z1 - upy * z0;
		len = x0 * x0 + x1 * x1 + x2 * x2;
		if (len > 0) {
			len = 1 / Math.sqrt(len);
			x0 *= len;
			x1 *= len;
			x2 *= len;
		}
		out[0] = x0;
		out[1] = x1;
		out[2] = x2;
		out[3] = 0;
		out[4] = z1 * x2 - z2 * x1;
		out[5] = z2 * x0 - z0 * x2;
		out[6] = z0 * x1 - z1 * x0;
		out[7] = 0;
		out[8] = z0;
		out[9] = z1;
		out[10] = z2;
		out[11] = 0;
		out[12] = eyex;
		out[13] = eyey;
		out[14] = eyez;
		out[15] = 1;
		return out;
	}
	/**
	* Returns Frobenius norm of a {@link Mat4}
	* @category Static
	*
	* @param a - the matrix to calculate Frobenius norm of
	* @returns Frobenius norm
	*/
	static frob(a) {
		return Math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2] + a[3] * a[3] + a[4] * a[4] + a[5] * a[5] + a[6] * a[6] + a[7] * a[7] + a[8] * a[8] + a[9] * a[9] + a[10] * a[10] + a[11] * a[11] + a[12] * a[12] + a[13] * a[13] + a[14] * a[14] + a[15] * a[15]);
	}
	/**
	* Adds two {@link Mat4}'s
	* @category Static
	*
	* @param out - the receiving matrix
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static add(out, a, b) {
		out[0] = a[0] + b[0];
		out[1] = a[1] + b[1];
		out[2] = a[2] + b[2];
		out[3] = a[3] + b[3];
		out[4] = a[4] + b[4];
		out[5] = a[5] + b[5];
		out[6] = a[6] + b[6];
		out[7] = a[7] + b[7];
		out[8] = a[8] + b[8];
		out[9] = a[9] + b[9];
		out[10] = a[10] + b[10];
		out[11] = a[11] + b[11];
		out[12] = a[12] + b[12];
		out[13] = a[13] + b[13];
		out[14] = a[14] + b[14];
		out[15] = a[15] + b[15];
		return out;
	}
	/**
	* Subtracts matrix b from matrix a
	* @category Static
	*
	* @param out - the receiving matrix
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static subtract(out, a, b) {
		out[0] = a[0] - b[0];
		out[1] = a[1] - b[1];
		out[2] = a[2] - b[2];
		out[3] = a[3] - b[3];
		out[4] = a[4] - b[4];
		out[5] = a[5] - b[5];
		out[6] = a[6] - b[6];
		out[7] = a[7] - b[7];
		out[8] = a[8] - b[8];
		out[9] = a[9] - b[9];
		out[10] = a[10] - b[10];
		out[11] = a[11] - b[11];
		out[12] = a[12] - b[12];
		out[13] = a[13] - b[13];
		out[14] = a[14] - b[14];
		out[15] = a[15] - b[15];
		return out;
	}
	/**
	* Alias for {@link Mat4.subtract}
	* @category Static
	*/
	static sub(out, a, b) {
		return out;
	}
	/**
	* Multiply each element of the matrix by a scalar.
	* @category Static
	*
	* @param out - the receiving matrix
	* @param a - the matrix to scale
	* @param b - amount to scale the matrix's elements by
	* @returns `out`
	*/
	static multiplyScalar(out, a, b) {
		out[0] = a[0] * b;
		out[1] = a[1] * b;
		out[2] = a[2] * b;
		out[3] = a[3] * b;
		out[4] = a[4] * b;
		out[5] = a[5] * b;
		out[6] = a[6] * b;
		out[7] = a[7] * b;
		out[8] = a[8] * b;
		out[9] = a[9] * b;
		out[10] = a[10] * b;
		out[11] = a[11] * b;
		out[12] = a[12] * b;
		out[13] = a[13] * b;
		out[14] = a[14] * b;
		out[15] = a[15] * b;
		return out;
	}
	/**
	* Adds two mat4's after multiplying each element of the second operand by a scalar value.
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @param scale - the amount to scale b's elements by before adding
	* @returns `out`
	*/
	static multiplyScalarAndAdd(out, a, b, scale) {
		out[0] = a[0] + b[0] * scale;
		out[1] = a[1] + b[1] * scale;
		out[2] = a[2] + b[2] * scale;
		out[3] = a[3] + b[3] * scale;
		out[4] = a[4] + b[4] * scale;
		out[5] = a[5] + b[5] * scale;
		out[6] = a[6] + b[6] * scale;
		out[7] = a[7] + b[7] * scale;
		out[8] = a[8] + b[8] * scale;
		out[9] = a[9] + b[9] * scale;
		out[10] = a[10] + b[10] * scale;
		out[11] = a[11] + b[11] * scale;
		out[12] = a[12] + b[12] * scale;
		out[13] = a[13] + b[13] * scale;
		out[14] = a[14] + b[14] * scale;
		out[15] = a[15] + b[15] * scale;
		return out;
	}
	/**
	* Returns whether or not two {@link Mat4}s have exactly the same elements in the same position (when compared with ===)
	* @category Static
	*
	* @param a - The first matrix.
	* @param b - The second matrix.
	* @returns True if the matrices are equal, false otherwise.
	*/
	static exactEquals(a, b) {
		return a[0] === b[0] && a[1] === b[1] && a[2] === b[2] && a[3] === b[3] && a[4] === b[4] && a[5] === b[5] && a[6] === b[6] && a[7] === b[7] && a[8] === b[8] && a[9] === b[9] && a[10] === b[10] && a[11] === b[11] && a[12] === b[12] && a[13] === b[13] && a[14] === b[14] && a[15] === b[15];
	}
	/**
	* Returns whether or not two {@link Mat4}s have approximately the same elements in the same position.
	* @category Static
	*
	* @param a - The first matrix.
	* @param b - The second matrix.
	* @returns True if the matrices are equal, false otherwise.
	*/
	static equals(a, b) {
		const a0 = a[0];
		const a1 = a[1];
		const a2 = a[2];
		const a3 = a[3];
		const a4 = a[4];
		const a5 = a[5];
		const a6 = a[6];
		const a7 = a[7];
		const a8 = a[8];
		const a9 = a[9];
		const a10 = a[10];
		const a11 = a[11];
		const a12 = a[12];
		const a13 = a[13];
		const a14 = a[14];
		const a15 = a[15];
		const b0 = b[0];
		const b1 = b[1];
		const b2 = b[2];
		const b3 = b[3];
		const b4 = b[4];
		const b5 = b[5];
		const b6 = b[6];
		const b7 = b[7];
		const b8 = b[8];
		const b9 = b[9];
		const b10 = b[10];
		const b11 = b[11];
		const b12 = b[12];
		const b13 = b[13];
		const b14 = b[14];
		const b15 = b[15];
		return Math.abs(a0 - b0) <= 1e-6 * Math.max(1, Math.abs(a0), Math.abs(b0)) && Math.abs(a1 - b1) <= 1e-6 * Math.max(1, Math.abs(a1), Math.abs(b1)) && Math.abs(a2 - b2) <= 1e-6 * Math.max(1, Math.abs(a2), Math.abs(b2)) && Math.abs(a3 - b3) <= 1e-6 * Math.max(1, Math.abs(a3), Math.abs(b3)) && Math.abs(a4 - b4) <= 1e-6 * Math.max(1, Math.abs(a4), Math.abs(b4)) && Math.abs(a5 - b5) <= 1e-6 * Math.max(1, Math.abs(a5), Math.abs(b5)) && Math.abs(a6 - b6) <= 1e-6 * Math.max(1, Math.abs(a6), Math.abs(b6)) && Math.abs(a7 - b7) <= 1e-6 * Math.max(1, Math.abs(a7), Math.abs(b7)) && Math.abs(a8 - b8) <= 1e-6 * Math.max(1, Math.abs(a8), Math.abs(b8)) && Math.abs(a9 - b9) <= 1e-6 * Math.max(1, Math.abs(a9), Math.abs(b9)) && Math.abs(a10 - b10) <= 1e-6 * Math.max(1, Math.abs(a10), Math.abs(b10)) && Math.abs(a11 - b11) <= 1e-6 * Math.max(1, Math.abs(a11), Math.abs(b11)) && Math.abs(a12 - b12) <= 1e-6 * Math.max(1, Math.abs(a12), Math.abs(b12)) && Math.abs(a13 - b13) <= 1e-6 * Math.max(1, Math.abs(a13), Math.abs(b13)) && Math.abs(a14 - b14) <= 1e-6 * Math.max(1, Math.abs(a14), Math.abs(b14)) && Math.abs(a15 - b15) <= 1e-6 * Math.max(1, Math.abs(a15), Math.abs(b15));
	}
	/**
	* Returns a string representation of a {@link Mat4}
	* @category Static
	*
	* @param a - matrix to represent as a string
	* @returns string representation of the matrix
	*/
	static str(a) {
		return `Mat4(${a.join(", ")})`;
	}
};
const tmpVec3 = new Float32Array(3);
Mat4.prototype.mul = Mat4.prototype.multiply;
Mat4.sub = Mat4.subtract;
Mat4.mul = Mat4.multiply;
Mat4.frustum = Mat4.frustumNO;
Mat4.perspective = Mat4.perspectiveNO;
Mat4.ortho = Mat4.orthoNO;
//#endregion
//#region ../../node_modules/.pnpm/gl-matrix@4.0.0-beta.2/node_modules/gl-matrix/dist/esm/vec3.js
/**
* 3 Dimensional Vector
*/
var Vec3 = class Vec3 extends Float32Array {
	/**
	* The number of bytes in a {@link Vec3}.
	*/
	static BYTE_LENGTH = 3 * Float32Array.BYTES_PER_ELEMENT;
	/**
	* Create a {@link Vec3}.
	*/
	constructor(...values) {
		switch (values.length) {
			case 3:
				super(values);
				break;
			case 2:
				super(values[0], values[1], 3);
				break;
			case 1: {
				const v = values[0];
				if (typeof v === "number") super([
					v,
					v,
					v
				]);
				else super(v, 0, 3);
				break;
			}
			default:
				super(3);
				break;
		}
	}
	/**
	* The x component of the vector. Equivalent to `this[0];`
	* @category Vector components
	*/
	get x() {
		return this[0];
	}
	set x(value) {
		this[0] = value;
	}
	/**
	* The y component of the vector. Equivalent to `this[1];`
	* @category Vector components
	*/
	get y() {
		return this[1];
	}
	set y(value) {
		this[1] = value;
	}
	/**
	* The z component of the vector. Equivalent to `this[2];`
	* @category Vector components
	*/
	get z() {
		return this[2];
	}
	set z(value) {
		this[2] = value;
	}
	/**
	* The r component of the vector. Equivalent to `this[0];`
	* @category Color components
	*/
	get r() {
		return this[0];
	}
	set r(value) {
		this[0] = value;
	}
	/**
	* The g component of the vector. Equivalent to `this[1];`
	* @category Color components
	*/
	get g() {
		return this[1];
	}
	set g(value) {
		this[1] = value;
	}
	/**
	* The b component of the vector. Equivalent to `this[2];`
	* @category Color components
	*/
	get b() {
		return this[2];
	}
	set b(value) {
		this[2] = value;
	}
	/**
	* The magnitude (length) of this.
	* Equivalent to `Vec3.magnitude(this);`
	*
	* Magnitude is used because the `length` attribute is already defined by
	* TypedArrays to mean the number of elements in the array.
	*/
	get magnitude() {
		const x = this[0];
		const y = this[1];
		const z = this[2];
		return Math.sqrt(x * x + y * y + z * z);
	}
	/**
	* Alias for {@link Vec3.magnitude}
	*/
	get mag() {
		return this.magnitude;
	}
	/**
	* The squared magnitude (length) of `this`.
	* Equivalent to `Vec3.squaredMagnitude(this);`
	*/
	get squaredMagnitude() {
		const x = this[0];
		const y = this[1];
		const z = this[2];
		return x * x + y * y + z * z;
	}
	/**
	* Alias for {@link Vec3.squaredMagnitude}
	*/
	get sqrMag() {
		return this.squaredMagnitude;
	}
	/**
	* A string representation of `this`
	* Equivalent to `Vec3.str(this);`
	*/
	get str() {
		return Vec3.str(this);
	}
	/**
	* Copy the values from another {@link Vec3} into `this`.
	*
	* @param a the source vector
	* @returns `this`
	*/
	copy(a) {
		this.set(a);
		return this;
	}
	/**
	* Adds a {@link Vec3} to `this`.
	* Equivalent to `Vec3.add(this, this, b);`
	*
	* @param b - The vector to add to `this`
	* @returns `this`
	*/
	add(b) {
		this[0] += b[0];
		this[1] += b[1];
		this[2] += b[2];
		return this;
	}
	/**
	* Subtracts a {@link Vec3} from `this`.
	* Equivalent to `Vec3.subtract(this, this, b);`
	*
	* @param b - The vector to subtract from `this`
	* @returns `this`
	*/
	subtract(b) {
		this[0] -= b[0];
		this[1] -= b[1];
		this[2] -= b[2];
		return this;
	}
	/**
	* Alias for {@link Vec3.subtract}
	*/
	sub(b) {
		return this;
	}
	/**
	* Multiplies `this` by a {@link Vec3}.
	* Equivalent to `Vec3.multiply(this, this, b);`
	*
	* @param b - The vector to multiply `this` by
	* @returns `this`
	*/
	multiply(b) {
		this[0] *= b[0];
		this[1] *= b[1];
		this[2] *= b[2];
		return this;
	}
	/**
	* Alias for {@link Vec3.multiply}
	*/
	mul(b) {
		return this;
	}
	/**
	* Divides `this` by a {@link Vec3}.
	* Equivalent to `Vec3.divide(this, this, b);`
	*
	* @param b - The vector to divide `this` by
	* @returns `this`
	*/
	divide(b) {
		this[0] /= b[0];
		this[1] /= b[1];
		this[2] /= b[2];
		return this;
	}
	/**
	* Alias for {@link Vec3.divide}
	*/
	div(b) {
		return this;
	}
	/**
	* Scales `this` by a scalar number.
	* Equivalent to `Vec3.scale(this, this, b);`
	*
	* @param b - Amount to scale `this` by
	* @returns `this`
	*/
	scale(b) {
		this[0] *= b;
		this[1] *= b;
		this[2] *= b;
		return this;
	}
	/**
	* Calculates `this` scaled by a scalar value then adds the result to `this`.
	* Equivalent to `Vec3.scaleAndAdd(this, this, b, scale);`
	*
	* @param b - The vector to add to `this`
	* @param scale - The amount to scale `b` by before adding
	* @returns `this`
	*/
	scaleAndAdd(b, scale) {
		this[0] += b[0] * scale;
		this[1] += b[1] * scale;
		this[2] += b[2] * scale;
		return this;
	}
	/**
	* Calculates the euclidian distance between another {@link Vec3} and `this`.
	* Equivalent to `Vec3.distance(this, b);`
	*
	* @param b - The vector to calculate the distance to
	* @returns Distance between `this` and `b`
	*/
	distance(b) {
		return Vec3.distance(this, b);
	}
	/**
	* Alias for {@link Vec3.distance}
	*/
	dist(b) {
		return 0;
	}
	/**
	* Calculates the squared euclidian distance between another {@link Vec3} and `this`.
	* Equivalent to `Vec3.squaredDistance(this, b);`
	*
	* @param b The vector to calculate the squared distance to
	* @returns Squared distance between `this` and `b`
	*/
	squaredDistance(b) {
		return Vec3.squaredDistance(this, b);
	}
	/**
	* Alias for {@link Vec3.squaredDistance}
	*/
	sqrDist(b) {
		return 0;
	}
	/**
	* Negates the components of `this`.
	* Equivalent to `Vec3.negate(this, this);`
	*
	* @returns `this`
	*/
	negate() {
		this[0] *= -1;
		this[1] *= -1;
		this[2] *= -1;
		return this;
	}
	/**
	* Inverts the components of `this`.
	* Equivalent to `Vec3.inverse(this, this);`
	*
	* @returns `this`
	*/
	invert() {
		this[0] = 1 / this[0];
		this[1] = 1 / this[1];
		this[2] = 1 / this[2];
		return this;
	}
	/**
	* Sets each component of `this` to it's absolute value.
	* Equivalent to `Vec3.abs(this, this);`
	*
	* @returns `this`
	*/
	abs() {
		this[0] = Math.abs(this[0]);
		this[1] = Math.abs(this[1]);
		this[2] = Math.abs(this[2]);
		return this;
	}
	/**
	* Calculates the dot product of this and another {@link Vec3}.
	* Equivalent to `Vec3.dot(this, b);`
	*
	* @param b - The second operand
	* @returns Dot product of `this` and `b`
	*/
	dot(b) {
		return this[0] * b[0] + this[1] * b[1] + this[2] * b[2];
	}
	/**
	* Normalize `this`.
	* Equivalent to `Vec3.normalize(this, this);`
	*
	* @returns `this`
	*/
	normalize() {
		return Vec3.normalize(this, this);
	}
	/**
	* Creates a new, empty vec3
	* @category Static
	*
	* @returns a new 3D vector
	*/
	static create() {
		return new Vec3();
	}
	/**
	* Creates a new vec3 initialized with values from an existing vector
	* @category Static
	*
	* @param a - vector to clone
	* @returns a new 3D vector
	*/
	static clone(a) {
		return new Vec3(a);
	}
	/**
	* Calculates the magnitude (length) of a {@link Vec3}
	* @category Static
	*
	* @param a - Vector to calculate magnitude of
	* @returns Magnitude of a
	*/
	static magnitude(a) {
		let x = a[0];
		let y = a[1];
		let z = a[2];
		return Math.sqrt(x * x + y * y + z * z);
	}
	/**
	* Alias for {@link Vec3.magnitude}
	* @category Static
	*/
	static mag(a) {
		return 0;
	}
	/**
	* Alias for {@link Vec3.magnitude}
	* @category Static
	* @deprecated Use {@link Vec3.magnitude} to avoid conflicts with builtin `length` methods/attribs
	*
	* @param a - vector to calculate length of
	* @returns length of a
	*/
	static length(a) {
		return 0;
	}
	/**
	* Alias for {@link Vec3.magnitude}
	* @category Static
	* @deprecated Use {@link Vec3.mag}
	*/
	static len(a) {
		return 0;
	}
	/**
	* Creates a new vec3 initialized with the given values
	* @category Static
	*
	* @param x - X component
	* @param y - Y component
	* @param z - Z component
	* @returns a new 3D vector
	*/
	static fromValues(x, y, z) {
		return new Vec3(x, y, z);
	}
	/**
	* Copy the values from one vec3 to another
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the source vector
	* @returns `out`
	*/
	static copy(out, a) {
		out[0] = a[0];
		out[1] = a[1];
		out[2] = a[2];
		return out;
	}
	/**
	* Set the components of a vec3 to the given values
	* @category Static
	*
	* @param out - the receiving vector
	* @param x - X component
	* @param y - Y component
	* @param z - Z component
	* @returns `out`
	*/
	static set(out, x, y, z) {
		out[0] = x;
		out[1] = y;
		out[2] = z;
		return out;
	}
	/**
	* Adds two {@link Vec3}s
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - The first operand
	* @param b - The second operand
	* @returns `out`
	*/
	static add(out, a, b) {
		out[0] = a[0] + b[0];
		out[1] = a[1] + b[1];
		out[2] = a[2] + b[2];
		return out;
	}
	/**
	* Subtracts vector b from vector a
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static subtract(out, a, b) {
		out[0] = a[0] - b[0];
		out[1] = a[1] - b[1];
		out[2] = a[2] - b[2];
		return out;
	}
	/**
	* Alias for {@link Vec3.subtract}
	* @category Static
	*/
	static sub(out, a, b) {
		return [
			0,
			0,
			0
		];
	}
	/**
	* Multiplies two vec3's
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static multiply(out, a, b) {
		out[0] = a[0] * b[0];
		out[1] = a[1] * b[1];
		out[2] = a[2] * b[2];
		return out;
	}
	/**
	* Alias for {@link Vec3.multiply}
	* @category Static
	*/
	static mul(out, a, b) {
		return [
			0,
			0,
			0
		];
	}
	/**
	* Divides two vec3's
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static divide(out, a, b) {
		out[0] = a[0] / b[0];
		out[1] = a[1] / b[1];
		out[2] = a[2] / b[2];
		return out;
	}
	/**
	* Alias for {@link Vec3.divide}
	* @category Static
	*/
	static div(out, a, b) {
		return [
			0,
			0,
			0
		];
	}
	/**
	* Math.ceil the components of a vec3
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - vector to ceil
	* @returns `out`
	*/
	static ceil(out, a) {
		out[0] = Math.ceil(a[0]);
		out[1] = Math.ceil(a[1]);
		out[2] = Math.ceil(a[2]);
		return out;
	}
	/**
	* Math.floor the components of a vec3
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - vector to floor
	* @returns `out`
	*/
	static floor(out, a) {
		out[0] = Math.floor(a[0]);
		out[1] = Math.floor(a[1]);
		out[2] = Math.floor(a[2]);
		return out;
	}
	/**
	* Returns the minimum of two vec3's
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static min(out, a, b) {
		out[0] = Math.min(a[0], b[0]);
		out[1] = Math.min(a[1], b[1]);
		out[2] = Math.min(a[2], b[2]);
		return out;
	}
	/**
	* Returns the maximum of two vec3's
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static max(out, a, b) {
		out[0] = Math.max(a[0], b[0]);
		out[1] = Math.max(a[1], b[1]);
		out[2] = Math.max(a[2], b[2]);
		return out;
	}
	/**
	* symmetric round the components of a vec3
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - vector to round
	* @returns `out`
	*/
	/**
	* Scales a vec3 by a scalar number
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the vector to scale
	* @param scale - amount to scale the vector by
	* @returns `out`
	*/
	static scale(out, a, scale) {
		out[0] = a[0] * scale;
		out[1] = a[1] * scale;
		out[2] = a[2] * scale;
		return out;
	}
	/**
	* Adds two vec3's after scaling the second operand by a scalar value
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @param scale - the amount to scale b by before adding
	* @returns `out`
	*/
	static scaleAndAdd(out, a, b, scale) {
		out[0] = a[0] + b[0] * scale;
		out[1] = a[1] + b[1] * scale;
		out[2] = a[2] + b[2] * scale;
		return out;
	}
	/**
	* Calculates the euclidian distance between two vec3's
	* @category Static
	*
	* @param a - the first operand
	* @param b - the second operand
	* @returns distance between a and b
	*/
	static distance(a, b) {
		const x = b[0] - a[0];
		const y = b[1] - a[1];
		const z = b[2] - a[2];
		return Math.sqrt(x * x + y * y + z * z);
	}
	/**
	* Alias for {@link Vec3.distance}
	*/
	static dist(a, b) {
		return 0;
	}
	/**
	* Calculates the squared euclidian distance between two vec3's
	* @category Static
	*
	* @param a - the first operand
	* @param b - the second operand
	* @returns squared distance between a and b
	*/
	static squaredDistance(a, b) {
		const x = b[0] - a[0];
		const y = b[1] - a[1];
		const z = b[2] - a[2];
		return x * x + y * y + z * z;
	}
	/**
	* Alias for {@link Vec3.squaredDistance}
	*/
	static sqrDist(a, b) {
		return 0;
	}
	/**
	* Calculates the squared length of a vec3
	* @category Static
	*
	* @param a - vector to calculate squared length of
	* @returns squared length of a
	*/
	static squaredLength(a) {
		const x = a[0];
		const y = a[1];
		const z = a[2];
		return x * x + y * y + z * z;
	}
	/**
	* Alias for {@link Vec3.squaredLength}
	*/
	static sqrLen(a, b) {
		return 0;
	}
	/**
	* Negates the components of a vec3
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - vector to negate
	* @returns `out`
	*/
	static negate(out, a) {
		out[0] = -a[0];
		out[1] = -a[1];
		out[2] = -a[2];
		return out;
	}
	/**
	* Returns the inverse of the components of a vec3
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - vector to invert
	* @returns `out`
	*/
	static inverse(out, a) {
		out[0] = 1 / a[0];
		out[1] = 1 / a[1];
		out[2] = 1 / a[2];
		return out;
	}
	/**
	* Returns the absolute value of the components of a {@link Vec3}
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - Vector to compute the absolute values of
	* @returns `out`
	*/
	static abs(out, a) {
		out[0] = Math.abs(a[0]);
		out[1] = Math.abs(a[1]);
		out[2] = Math.abs(a[2]);
		return out;
	}
	/**
	* Normalize a vec3
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - vector to normalize
	* @returns `out`
	*/
	static normalize(out, a) {
		const x = a[0];
		const y = a[1];
		const z = a[2];
		let len = x * x + y * y + z * z;
		if (len > 0) len = 1 / Math.sqrt(len);
		out[0] = a[0] * len;
		out[1] = a[1] * len;
		out[2] = a[2] * len;
		return out;
	}
	/**
	* Calculates the dot product of two vec3's
	* @category Static
	*
	* @param a - the first operand
	* @param b - the second operand
	* @returns dot product of a and b
	*/
	static dot(a, b) {
		return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
	}
	/**
	* Computes the cross product of two vec3's
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static cross(out, a, b) {
		const ax = a[0], ay = a[1], az = a[2];
		const bx = b[0], by = b[1], bz = b[2];
		out[0] = ay * bz - az * by;
		out[1] = az * bx - ax * bz;
		out[2] = ax * by - ay * bx;
		return out;
	}
	/**
	* Performs a linear interpolation between two vec3's
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @param t - interpolation amount, in the range [0-1], between the two inputs
	* @returns `out`
	*/
	static lerp(out, a, b, t) {
		const ax = a[0];
		const ay = a[1];
		const az = a[2];
		out[0] = ax + t * (b[0] - ax);
		out[1] = ay + t * (b[1] - ay);
		out[2] = az + t * (b[2] - az);
		return out;
	}
	/**
	* Performs a spherical linear interpolation between two vec3's
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @param t - interpolation amount, in the range [0-1], between the two inputs
	* @returns `out`
	*/
	static slerp(out, a, b, t) {
		const angle = Math.acos(Math.min(Math.max(Vec3.dot(a, b), -1), 1));
		const sinTotal = Math.sin(angle);
		const ratioA = Math.sin((1 - t) * angle) / sinTotal;
		const ratioB = Math.sin(t * angle) / sinTotal;
		out[0] = ratioA * a[0] + ratioB * b[0];
		out[1] = ratioA * a[1] + ratioB * b[1];
		out[2] = ratioA * a[2] + ratioB * b[2];
		return out;
	}
	/**
	* Performs a hermite interpolation with two control points
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @param c - the third operand
	* @param d - the fourth operand
	* @param t - interpolation amount, in the range [0-1], between the two inputs
	* @returns `out`
	*/
	static hermite(out, a, b, c, d, t) {
		const factorTimes2 = t * t;
		const factor1 = factorTimes2 * (2 * t - 3) + 1;
		const factor2 = factorTimes2 * (t - 2) + t;
		const factor3 = factorTimes2 * (t - 1);
		const factor4 = factorTimes2 * (3 - 2 * t);
		out[0] = a[0] * factor1 + b[0] * factor2 + c[0] * factor3 + d[0] * factor4;
		out[1] = a[1] * factor1 + b[1] * factor2 + c[1] * factor3 + d[1] * factor4;
		out[2] = a[2] * factor1 + b[2] * factor2 + c[2] * factor3 + d[2] * factor4;
		return out;
	}
	/**
	* Performs a bezier interpolation with two control points
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @param c - the third operand
	* @param d - the fourth operand
	* @param t - interpolation amount, in the range [0-1], between the two inputs
	* @returns `out`
	*/
	static bezier(out, a, b, c, d, t) {
		const inverseFactor = 1 - t;
		const inverseFactorTimesTwo = inverseFactor * inverseFactor;
		const factorTimes2 = t * t;
		const factor1 = inverseFactorTimesTwo * inverseFactor;
		const factor2 = 3 * t * inverseFactorTimesTwo;
		const factor3 = 3 * factorTimes2 * inverseFactor;
		const factor4 = factorTimes2 * t;
		out[0] = a[0] * factor1 + b[0] * factor2 + c[0] * factor3 + d[0] * factor4;
		out[1] = a[1] * factor1 + b[1] * factor2 + c[1] * factor3 + d[1] * factor4;
		out[2] = a[2] * factor1 + b[2] * factor2 + c[2] * factor3 + d[2] * factor4;
		return out;
	}
	/**
	* Generates a random vector with the given scale
	* @category Static
	*
	* @param out - the receiving vector
	* @param {Number} [scale] Length of the resulting vector. If omitted, a unit vector will be returned
	* @returns `out`
	*/
	/**
	* Transforms the vec3 with a mat4.
	* 4th vector component is implicitly '1'
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the vector to transform
	* @param m - matrix to transform with
	* @returns `out`
	*/
	static transformMat4(out, a, m) {
		const x = a[0], y = a[1], z = a[2];
		const w = m[3] * x + m[7] * y + m[11] * z + m[15] || 1;
		out[0] = (m[0] * x + m[4] * y + m[8] * z + m[12]) / w;
		out[1] = (m[1] * x + m[5] * y + m[9] * z + m[13]) / w;
		out[2] = (m[2] * x + m[6] * y + m[10] * z + m[14]) / w;
		return out;
	}
	/**
	* Transforms the vec3 with a mat3.
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the vector to transform
	* @param m - the 3x3 matrix to transform with
	* @returns `out`
	*/
	static transformMat3(out, a, m) {
		let x = a[0], y = a[1], z = a[2];
		out[0] = x * m[0] + y * m[3] + z * m[6];
		out[1] = x * m[1] + y * m[4] + z * m[7];
		out[2] = x * m[2] + y * m[5] + z * m[8];
		return out;
	}
	/**
	* Transforms the vec3 with a quat
	* Can also be used for dual quaternions. (Multiply it with the real part)
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the vector to transform
	* @param q - quaternion to transform with
	* @returns `out`
	*/
	static transformQuat(out, a, q) {
		const qx = q[0];
		const qy = q[1];
		const qz = q[2];
		const w2 = q[3] * 2;
		const x = a[0];
		const y = a[1];
		const z = a[2];
		const uvx = qy * z - qz * y;
		const uvy = qz * x - qx * z;
		const uvz = qx * y - qy * x;
		const uuvx = (qy * uvz - qz * uvy) * 2;
		const uuvy = (qz * uvx - qx * uvz) * 2;
		const uuvz = (qx * uvy - qy * uvx) * 2;
		out[0] = x + uvx * w2 + uuvx;
		out[1] = y + uvy * w2 + uuvy;
		out[2] = z + uvz * w2 + uuvz;
		return out;
	}
	/**
	* Rotate a 3D vector around the x-axis
	* @param out - The receiving vec3
	* @param a - The vec3 point to rotate
	* @param b - The origin of the rotation
	* @param rad - The angle of rotation in radians
	* @returns `out`
	*/
	static rotateX(out, a, b, rad) {
		const by = b[1];
		const bz = b[2];
		const py = a[1] - by;
		const pz = a[2] - bz;
		out[0] = a[0];
		out[1] = py * Math.cos(rad) - pz * Math.sin(rad) + by;
		out[2] = py * Math.sin(rad) + pz * Math.cos(rad) + bz;
		return out;
	}
	/**
	* Rotate a 3D vector around the y-axis
	* @param out - The receiving vec3
	* @param a - The vec3 point to rotate
	* @param b - The origin of the rotation
	* @param rad - The angle of rotation in radians
	* @returns `out`
	*/
	static rotateY(out, a, b, rad) {
		const bx = b[0];
		const bz = b[2];
		const px = a[0] - bx;
		const pz = a[2] - bz;
		out[0] = pz * Math.sin(rad) + px * Math.cos(rad) + bx;
		out[1] = a[1];
		out[2] = pz * Math.cos(rad) - px * Math.sin(rad) + bz;
		return out;
	}
	/**
	* Rotate a 3D vector around the z-axis
	* @param out - The receiving vec3
	* @param a - The vec3 point to rotate
	* @param b - The origin of the rotation
	* @param rad - The angle of rotation in radians
	* @returns `out`
	*/
	static rotateZ(out, a, b, rad) {
		const bx = b[0];
		const by = b[1];
		const px = a[0] - bx;
		const py = a[1] - by;
		out[0] = px * Math.cos(rad) - py * Math.sin(rad) + bx;
		out[1] = px * Math.sin(rad) + py * Math.cos(rad) + by;
		out[2] = b[2];
		return out;
	}
	/**
	* Get the angle between two 3D vectors
	* @param a - The first operand
	* @param b - The second operand
	* @returns The angle in radians
	*/
	static angle(a, b) {
		const ax = a[0];
		const ay = a[1];
		const az = a[2];
		const bx = b[0];
		const by = b[1];
		const bz = b[2];
		const mag = Math.sqrt((ax * ax + ay * ay + az * az) * (bx * bx + by * by + bz * bz));
		const cosine = mag && Vec3.dot(a, b) / mag;
		return Math.acos(Math.min(Math.max(cosine, -1), 1));
	}
	/**
	* Set the components of a vec3 to zero
	* @category Static
	*
	* @param out - the receiving vector
	* @returns `out`
	*/
	static zero(out) {
		out[0] = 0;
		out[1] = 0;
		out[2] = 0;
		return out;
	}
	/**
	* Returns a string representation of a vector
	* @category Static
	*
	* @param a - vector to represent as a string
	* @returns string representation of the vector
	*/
	static str(a) {
		return `Vec3(${a.join(", ")})`;
	}
	/**
	* Returns whether or not the vectors have exactly the same elements in the same position (when compared with ===)
	* @category Static
	*
	* @param a - The first vector.
	* @param b - The second vector.
	* @returns True if the vectors are equal, false otherwise.
	*/
	static exactEquals(a, b) {
		return a[0] === b[0] && a[1] === b[1] && a[2] === b[2];
	}
	/**
	* Returns whether or not the vectors have approximately the same elements in the same position.
	* @category Static
	*
	* @param a - The first vector.
	* @param b - The second vector.
	* @returns True if the vectors are equal, false otherwise.
	*/
	static equals(a, b) {
		const a0 = a[0];
		const a1 = a[1];
		const a2 = a[2];
		const b0 = b[0];
		const b1 = b[1];
		const b2 = b[2];
		return Math.abs(a0 - b0) <= 1e-6 * Math.max(1, Math.abs(a0), Math.abs(b0)) && Math.abs(a1 - b1) <= 1e-6 * Math.max(1, Math.abs(a1), Math.abs(b1)) && Math.abs(a2 - b2) <= 1e-6 * Math.max(1, Math.abs(a2), Math.abs(b2));
	}
};
Vec3.prototype.sub = Vec3.prototype.subtract;
Vec3.prototype.mul = Vec3.prototype.multiply;
Vec3.prototype.div = Vec3.prototype.divide;
Vec3.prototype.dist = Vec3.prototype.distance;
Vec3.prototype.sqrDist = Vec3.prototype.squaredDistance;
Vec3.sub = Vec3.subtract;
Vec3.mul = Vec3.multiply;
Vec3.div = Vec3.divide;
Vec3.dist = Vec3.distance;
Vec3.sqrDist = Vec3.squaredDistance;
Vec3.sqrLen = Vec3.squaredLength;
Vec3.mag = Vec3.magnitude;
Vec3.length = Vec3.magnitude;
Vec3.len = Vec3.magnitude;
//#endregion
//#region ../../node_modules/.pnpm/gl-matrix@4.0.0-beta.2/node_modules/gl-matrix/dist/esm/vec4.js
/**
* 4 Dimensional Vector
*/
var Vec4 = class Vec4 extends Float32Array {
	/**
	* The number of bytes in a {@link Vec4}.
	*/
	static BYTE_LENGTH = 4 * Float32Array.BYTES_PER_ELEMENT;
	/**
	* Create a {@link Vec4}.
	*/
	constructor(...values) {
		switch (values.length) {
			case 4:
				super(values);
				break;
			case 2:
				super(values[0], values[1], 4);
				break;
			case 1: {
				const v = values[0];
				if (typeof v === "number") super([
					v,
					v,
					v,
					v
				]);
				else super(v, 0, 4);
				break;
			}
			default:
				super(4);
				break;
		}
	}
	/**
	* The x component of the vector. Equivalent to `this[0];`
	* @category Vector components
	*/
	get x() {
		return this[0];
	}
	set x(value) {
		this[0] = value;
	}
	/**
	* The y component of the vector. Equivalent to `this[1];`
	* @category Vector components
	*/
	get y() {
		return this[1];
	}
	set y(value) {
		this[1] = value;
	}
	/**
	* The z component of the vector. Equivalent to `this[2];`
	* @category Vector components
	*/
	get z() {
		return this[2];
	}
	set z(value) {
		this[2] = value;
	}
	/**
	* The w component of the vector. Equivalent to `this[3];`
	* @category Vector components
	*/
	get w() {
		return this[3];
	}
	set w(value) {
		this[3] = value;
	}
	/**
	* The r component of the vector. Equivalent to `this[0];`
	* @category Color components
	*/
	get r() {
		return this[0];
	}
	set r(value) {
		this[0] = value;
	}
	/**
	* The g component of the vector. Equivalent to `this[1];`
	* @category Color components
	*/
	get g() {
		return this[1];
	}
	set g(value) {
		this[1] = value;
	}
	/**
	* The b component of the vector. Equivalent to `this[2];`
	* @category Color components
	*/
	get b() {
		return this[2];
	}
	set b(value) {
		this[2] = value;
	}
	/**
	* The a component of the vector. Equivalent to `this[3];`
	* @category Color components
	*/
	get a() {
		return this[3];
	}
	set a(value) {
		this[3] = value;
	}
	/**
	* The magnitude (length) of this.
	* Equivalent to `Vec4.magnitude(this);`
	*
	* Magnitude is used because the `length` attribute is already defined by
	* TypedArrays to mean the number of elements in the array.
	*/
	get magnitude() {
		const x = this[0];
		const y = this[1];
		const z = this[2];
		const w = this[3];
		return Math.sqrt(x * x + y * y + z * z + w * w);
	}
	/**
	* Alias for {@link Vec4.magnitude}
	*/
	get mag() {
		return this.magnitude;
	}
	/**
	* A string representation of `this`
	* Equivalent to `Vec4.str(this);`
	*/
	get str() {
		return Vec4.str(this);
	}
	/**
	* Copy the values from another {@link Vec4} into `this`.
	*
	* @param a the source vector
	* @returns `this`
	*/
	copy(a) {
		super.set(a);
		return this;
	}
	/**
	* Adds a {@link Vec4} to `this`.
	* Equivalent to `Vec4.add(this, this, b);`
	*
	* @param b - The vector to add to `this`
	* @returns `this`
	*/
	add(b) {
		this[0] += b[0];
		this[1] += b[1];
		this[2] += b[2];
		this[3] += b[3];
		return this;
	}
	/**
	* Subtracts a {@link Vec4} from `this`.
	* Equivalent to `Vec4.subtract(this, this, b);`
	*
	* @param b - The vector to subtract from `this`
	* @returns `this`
	*/
	subtract(b) {
		this[0] -= b[0];
		this[1] -= b[1];
		this[2] -= b[2];
		this[3] -= b[3];
		return this;
	}
	/**
	* Alias for {@link Vec4.subtract}
	*/
	sub(b) {
		return this;
	}
	/**
	* Multiplies `this` by a {@link Vec4}.
	* Equivalent to `Vec4.multiply(this, this, b);`
	*
	* @param b - The vector to multiply `this` by
	* @returns `this`
	*/
	multiply(b) {
		this[0] *= b[0];
		this[1] *= b[1];
		this[2] *= b[2];
		this[3] *= b[3];
		return this;
	}
	/**
	* Alias for {@link Vec4.multiply}
	*/
	mul(b) {
		return this;
	}
	/**
	* Divides `this` by a {@link Vec4}.
	* Equivalent to `Vec4.divide(this, this, b);`
	*
	* @param b - The vector to divide `this` by
	* @returns `this`
	*/
	divide(b) {
		this[0] /= b[0];
		this[1] /= b[1];
		this[2] /= b[2];
		this[3] /= b[3];
		return this;
	}
	/**
	* Alias for {@link Vec4.divide}
	*/
	div(b) {
		return this;
	}
	/**
	* Scales `this` by a scalar number.
	* Equivalent to `Vec4.scale(this, this, b);`
	*
	* @param b - Amount to scale `this` by
	* @returns `this`
	*/
	scale(b) {
		this[0] *= b;
		this[1] *= b;
		this[2] *= b;
		this[3] *= b;
		return this;
	}
	/**
	* Calculates `this` scaled by a scalar value then adds the result to `this`.
	* Equivalent to `Vec4.scaleAndAdd(this, this, b, scale);`
	*
	* @param b - The vector to add to `this`
	* @param scale - The amount to scale `b` by before adding
	* @returns `this`
	*/
	scaleAndAdd(b, scale) {
		this[0] += b[0] * scale;
		this[1] += b[1] * scale;
		this[2] += b[2] * scale;
		this[3] += b[3] * scale;
		return this;
	}
	/**
	* Calculates the euclidian distance between another {@link Vec4} and `this`.
	* Equivalent to `Vec4.distance(this, b);`
	*
	* @param b - The vector to calculate the distance to
	* @returns Distance between `this` and `b`
	*/
	distance(b) {
		return Vec4.distance(this, b);
	}
	/**
	* Alias for {@link Vec4.distance}
	*/
	dist(b) {
		return 0;
	}
	/**
	* Calculates the squared euclidian distance between another {@link Vec4} and `this`.
	* Equivalent to `Vec4.squaredDistance(this, b);`
	*
	* @param b The vector to calculate the squared distance to
	* @returns Squared distance between `this` and `b`
	*/
	squaredDistance(b) {
		return Vec4.squaredDistance(this, b);
	}
	/**
	* Alias for {@link Vec4.squaredDistance}
	*/
	sqrDist(b) {
		return 0;
	}
	/**
	* Negates the components of `this`.
	* Equivalent to `Vec4.negate(this, this);`
	*
	* @returns `this`
	*/
	negate() {
		this[0] *= -1;
		this[1] *= -1;
		this[2] *= -1;
		this[3] *= -1;
		return this;
	}
	/**
	* Inverts the components of `this`.
	* Equivalent to `Vec4.inverse(this, this);`
	*
	* @returns `this`
	*/
	invert() {
		this[0] = 1 / this[0];
		this[1] = 1 / this[1];
		this[2] = 1 / this[2];
		this[3] = 1 / this[3];
		return this;
	}
	/**
	* Sets each component of `this` to it's absolute value.
	* Equivalent to `Vec4.abs(this, this);`
	*
	* @returns `this`
	*/
	abs() {
		this[0] = Math.abs(this[0]);
		this[1] = Math.abs(this[1]);
		this[2] = Math.abs(this[2]);
		this[3] = Math.abs(this[3]);
		return this;
	}
	/**
	* Calculates the dot product of this and another {@link Vec4}.
	* Equivalent to `Vec4.dot(this, b);`
	*
	* @param b - The second operand
	* @returns Dot product of `this` and `b`
	*/
	dot(b) {
		return this[0] * b[0] + this[1] * b[1] + this[2] * b[2] + this[3] * b[3];
	}
	/**
	* Normalize `this`.
	* Equivalent to `Vec4.normalize(this, this);`
	*
	* @returns `this`
	*/
	normalize() {
		return Vec4.normalize(this, this);
	}
	/**
	* Creates a new, empty {@link Vec4}
	* @category Static
	*
	* @returns a new 4D vector
	*/
	static create() {
		return new Vec4();
	}
	/**
	* Creates a new {@link Vec4} initialized with values from an existing vector
	* @category Static
	*
	* @param a - vector to clone
	* @returns a new 4D vector
	*/
	static clone(a) {
		return new Vec4(a);
	}
	/**
	* Creates a new {@link Vec4} initialized with the given values
	* @category Static
	*
	* @param x - X component
	* @param y - Y component
	* @param z - Z component
	* @param w - W component
	* @returns a new 4D vector
	*/
	static fromValues(x, y, z, w) {
		return new Vec4(x, y, z, w);
	}
	/**
	* Copy the values from one {@link Vec4} to another
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the source vector
	* @returns `out`
	*/
	static copy(out, a) {
		out[0] = a[0];
		out[1] = a[1];
		out[2] = a[2];
		out[3] = a[3];
		return out;
	}
	/**
	* Set the components of a {@link Vec4} to the given values
	* @category Static
	*
	* @param out - the receiving vector
	* @param x - X component
	* @param y - Y component
	* @param z - Z component
	* @param w - W component
	* @returns `out`
	*/
	static set(out, x, y, z, w) {
		out[0] = x;
		out[1] = y;
		out[2] = z;
		out[3] = w;
		return out;
	}
	/**
	* Adds two {@link Vec4}s
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - The first operand
	* @param b - The second operand
	* @returns `out`
	*/
	static add(out, a, b) {
		out[0] = a[0] + b[0];
		out[1] = a[1] + b[1];
		out[2] = a[2] + b[2];
		out[3] = a[3] + b[3];
		return out;
	}
	/**
	* Subtracts vector b from vector a
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static subtract(out, a, b) {
		out[0] = a[0] - b[0];
		out[1] = a[1] - b[1];
		out[2] = a[2] - b[2];
		out[3] = a[3] - b[3];
		return out;
	}
	/**
	* Alias for {@link Vec4.subtract}
	* @category Static
	*/
	static sub(out, a, b) {
		return out;
	}
	/**
	* Multiplies two {@link Vec4}'s
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static multiply(out, a, b) {
		out[0] = a[0] * b[0];
		out[1] = a[1] * b[1];
		out[2] = a[2] * b[2];
		out[3] = a[3] * b[3];
		return out;
	}
	/**
	* Alias for {@link Vec4.multiply}
	* @category Static
	*/
	static mul(out, a, b) {
		return out;
	}
	/**
	* Divides two {@link Vec4}'s
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static divide(out, a, b) {
		out[0] = a[0] / b[0];
		out[1] = a[1] / b[1];
		out[2] = a[2] / b[2];
		out[3] = a[3] / b[3];
		return out;
	}
	/**
	* Alias for {@link Vec4.divide}
	* @category Static
	*/
	static div(out, a, b) {
		return out;
	}
	/**
	* Math.ceil the components of a {@link Vec4}
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - vector to ceil
	* @returns `out`
	*/
	static ceil(out, a) {
		out[0] = Math.ceil(a[0]);
		out[1] = Math.ceil(a[1]);
		out[2] = Math.ceil(a[2]);
		out[3] = Math.ceil(a[3]);
		return out;
	}
	/**
	* Math.floor the components of a {@link Vec4}
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - vector to floor
	* @returns `out`
	*/
	static floor(out, a) {
		out[0] = Math.floor(a[0]);
		out[1] = Math.floor(a[1]);
		out[2] = Math.floor(a[2]);
		out[3] = Math.floor(a[3]);
		return out;
	}
	/**
	* Returns the minimum of two {@link Vec4}'s
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static min(out, a, b) {
		out[0] = Math.min(a[0], b[0]);
		out[1] = Math.min(a[1], b[1]);
		out[2] = Math.min(a[2], b[2]);
		out[3] = Math.min(a[3], b[3]);
		return out;
	}
	/**
	* Returns the maximum of two {@link Vec4}'s
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @returns `out`
	*/
	static max(out, a, b) {
		out[0] = Math.max(a[0], b[0]);
		out[1] = Math.max(a[1], b[1]);
		out[2] = Math.max(a[2], b[2]);
		out[3] = Math.max(a[3], b[3]);
		return out;
	}
	/**
	* Math.round the components of a {@link Vec4}
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - vector to round
	* @returns `out`
	*/
	static round(out, a) {
		out[0] = Math.round(a[0]);
		out[1] = Math.round(a[1]);
		out[2] = Math.round(a[2]);
		out[3] = Math.round(a[3]);
		return out;
	}
	/**
	* Scales a {@link Vec4} by a scalar number
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the vector to scale
	* @param scale - amount to scale the vector by
	* @returns `out`
	*/
	static scale(out, a, scale) {
		out[0] = a[0] * scale;
		out[1] = a[1] * scale;
		out[2] = a[2] * scale;
		out[3] = a[3] * scale;
		return out;
	}
	/**
	* Adds two {@link Vec4}'s after scaling the second operand by a scalar value
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @param scale - the amount to scale b by before adding
	* @returns `out`
	*/
	static scaleAndAdd(out, a, b, scale) {
		out[0] = a[0] + b[0] * scale;
		out[1] = a[1] + b[1] * scale;
		out[2] = a[2] + b[2] * scale;
		out[3] = a[3] + b[3] * scale;
		return out;
	}
	/**
	* Calculates the euclidian distance between two {@link Vec4}'s
	* @category Static
	*
	* @param a - the first operand
	* @param b - the second operand
	* @returns distance between a and b
	*/
	static distance(a, b) {
		const x = b[0] - a[0];
		const y = b[1] - a[1];
		const z = b[2] - a[2];
		const w = b[3] - a[3];
		return Math.hypot(x, y, z, w);
	}
	/**
	* Alias for {@link Vec4.distance}
	* @category Static
	*/
	static dist(a, b) {
		return 0;
	}
	/**
	* Calculates the squared euclidian distance between two {@link Vec4}'s
	* @category Static
	*
	* @param a - the first operand
	* @param b - the second operand
	* @returns squared distance between a and b
	*/
	static squaredDistance(a, b) {
		const x = b[0] - a[0];
		const y = b[1] - a[1];
		const z = b[2] - a[2];
		const w = b[3] - a[3];
		return x * x + y * y + z * z + w * w;
	}
	/**
	* Alias for {@link Vec4.squaredDistance}
	* @category Static
	*/
	static sqrDist(a, b) {
		return 0;
	}
	/**
	* Calculates the magnitude (length) of a {@link Vec4}
	* @category Static
	*
	* @param a - vector to calculate length of
	* @returns length of `a`
	*/
	static magnitude(a) {
		const x = a[0];
		const y = a[1];
		const z = a[2];
		const w = a[3];
		return Math.sqrt(x * x + y * y + z * z + w * w);
	}
	/**
	* Alias for {@link Vec4.magnitude}
	* @category Static
	*/
	static mag(a) {
		return 0;
	}
	/**
	* Alias for {@link Vec4.magnitude}
	* @category Static
	* @deprecated Use {@link Vec4.magnitude} to avoid conflicts with builtin `length` methods/attribs
	*/
	static length(a) {
		return 0;
	}
	/**
	* Alias for {@link Vec4.magnitude}
	* @category Static
	* @deprecated Use {@link Vec4.mag}
	*/
	static len(a) {
		return 0;
	}
	/**
	* Calculates the squared length of a {@link Vec4}
	* @category Static
	*
	* @param a - vector to calculate squared length of
	* @returns squared length of a
	*/
	static squaredLength(a) {
		const x = a[0];
		const y = a[1];
		const z = a[2];
		const w = a[3];
		return x * x + y * y + z * z + w * w;
	}
	/**
	* Alias for {@link Vec4.squaredLength}
	* @category Static
	*/
	static sqrLen(a) {
		return 0;
	}
	/**
	* Negates the components of a {@link Vec4}
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - vector to negate
	* @returns `out`
	*/
	static negate(out, a) {
		out[0] = -a[0];
		out[1] = -a[1];
		out[2] = -a[2];
		out[3] = -a[3];
		return out;
	}
	/**
	* Returns the inverse of the components of a {@link Vec4}
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - vector to invert
	* @returns `out`
	*/
	static inverse(out, a) {
		out[0] = 1 / a[0];
		out[1] = 1 / a[1];
		out[2] = 1 / a[2];
		out[3] = 1 / a[3];
		return out;
	}
	/**
	* Returns the absolute value of the components of a {@link Vec4}
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - Vector to compute the absolute values of
	* @returns `out`
	*/
	static abs(out, a) {
		out[0] = Math.abs(a[0]);
		out[1] = Math.abs(a[1]);
		out[2] = Math.abs(a[2]);
		out[3] = Math.abs(a[3]);
		return out;
	}
	/**
	* Normalize a {@link Vec4}
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - vector to normalize
	* @returns `out`
	*/
	static normalize(out, a) {
		const x = a[0];
		const y = a[1];
		const z = a[2];
		const w = a[3];
		let len = x * x + y * y + z * z + w * w;
		if (len > 0) len = 1 / Math.sqrt(len);
		out[0] = x * len;
		out[1] = y * len;
		out[2] = z * len;
		out[3] = w * len;
		return out;
	}
	/**
	* Calculates the dot product of two {@link Vec4}'s
	* @category Static
	*
	* @param a - the first operand
	* @param b - the second operand
	* @returns dot product of a and b
	*/
	static dot(a, b) {
		return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
	}
	/**
	* Returns the cross-product of three vectors in a 4-dimensional space
	* @category Static
	*
	* @param out the receiving vector
	* @param u - the first vector
	* @param v - the second vector
	* @param w - the third vector
	* @returns result
	*/
	static cross(out, u, v, w) {
		const a = v[0] * w[1] - v[1] * w[0];
		const b = v[0] * w[2] - v[2] * w[0];
		const c = v[0] * w[3] - v[3] * w[0];
		const d = v[1] * w[2] - v[2] * w[1];
		const e = v[1] * w[3] - v[3] * w[1];
		const f = v[2] * w[3] - v[3] * w[2];
		const g = u[0];
		const h = u[1];
		const i = u[2];
		const j = u[3];
		out[0] = h * f - i * e + j * d;
		out[1] = -(g * f) + i * c - j * b;
		out[2] = g * e - h * c + j * a;
		out[3] = -(g * d) + h * b - i * a;
		return out;
	}
	/**
	* Performs a linear interpolation between two {@link Vec4}'s
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the first operand
	* @param b - the second operand
	* @param t - interpolation amount, in the range [0-1], between the two inputs
	* @returns `out`
	*/
	static lerp(out, a, b, t) {
		const ax = a[0];
		const ay = a[1];
		const az = a[2];
		const aw = a[3];
		out[0] = ax + t * (b[0] - ax);
		out[1] = ay + t * (b[1] - ay);
		out[2] = az + t * (b[2] - az);
		out[3] = aw + t * (b[3] - aw);
		return out;
	}
	/**
	* Generates a random vector with the given scale
	* @category Static
	*
	* @param out - the receiving vector
	* @param [scale] - Length of the resulting vector. If ommitted, a unit vector will be returned
	* @returns `out`
	*/
	/**
	* Transforms the {@link Vec4} with a {@link Mat4}.
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the vector to transform
	* @param m - matrix to transform with
	* @returns `out`
	*/
	static transformMat4(out, a, m) {
		const x = a[0];
		const y = a[1];
		const z = a[2];
		const w = a[3];
		out[0] = m[0] * x + m[4] * y + m[8] * z + m[12] * w;
		out[1] = m[1] * x + m[5] * y + m[9] * z + m[13] * w;
		out[2] = m[2] * x + m[6] * y + m[10] * z + m[14] * w;
		out[3] = m[3] * x + m[7] * y + m[11] * z + m[15] * w;
		return out;
	}
	/**
	* Transforms the {@link Vec4} with a {@link Quat}
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - the vector to transform
	* @param q - quaternion to transform with
	* @returns `out`
	*/
	static transformQuat(out, a, q) {
		const x = a[0];
		const y = a[1];
		const z = a[2];
		const qx = q[0];
		const qy = q[1];
		const qz = q[2];
		const qw = q[3];
		const ix = qw * x + qy * z - qz * y;
		const iy = qw * y + qz * x - qx * z;
		const iz = qw * z + qx * y - qy * x;
		const iw = -qx * x - qy * y - qz * z;
		out[0] = ix * qw + iw * -qx + iy * -qz - iz * -qy;
		out[1] = iy * qw + iw * -qy + iz * -qx - ix * -qz;
		out[2] = iz * qw + iw * -qz + ix * -qy - iy * -qx;
		out[3] = a[3];
		return out;
	}
	/**
	* Set the components of a {@link Vec4} to zero
	* @category Static
	*
	* @param out - the receiving vector
	* @returns `out`
	*/
	static zero(out) {
		out[0] = 0;
		out[1] = 0;
		out[2] = 0;
		out[3] = 0;
		return out;
	}
	/**
	* Returns a string representation of a {@link Vec4}
	* @category Static
	*
	* @param a - vector to represent as a string
	* @returns string representation of the vector
	*/
	static str(a) {
		return `Vec4(${a.join(", ")})`;
	}
	/**
	* Returns whether or not the vectors have exactly the same elements in the same position (when compared with ===)
	* @category Static
	*
	* @param a - The first vector.
	* @param b - The second vector.
	* @returns True if the vectors are equal, false otherwise.
	*/
	static exactEquals(a, b) {
		return a[0] === b[0] && a[1] === b[1] && a[2] === b[2] && a[3] === b[3];
	}
	/**
	* Returns whether or not the vectors have approximately the same elements in the same position.
	* @category Static
	*
	* @param a - The first vector.
	* @param b - The second vector.
	* @returns True if the vectors are equal, false otherwise.
	*/
	static equals(a, b) {
		const a0 = a[0];
		const a1 = a[1];
		const a2 = a[2];
		const a3 = a[3];
		const b0 = b[0];
		const b1 = b[1];
		const b2 = b[2];
		const b3 = b[3];
		return Math.abs(a0 - b0) <= 1e-6 * Math.max(1, Math.abs(a0), Math.abs(b0)) && Math.abs(a1 - b1) <= 1e-6 * Math.max(1, Math.abs(a1), Math.abs(b1)) && Math.abs(a2 - b2) <= 1e-6 * Math.max(1, Math.abs(a2), Math.abs(b2)) && Math.abs(a3 - b3) <= 1e-6 * Math.max(1, Math.abs(a3), Math.abs(b3));
	}
};
Vec4.prototype.sub = Vec4.prototype.subtract;
Vec4.prototype.mul = Vec4.prototype.multiply;
Vec4.prototype.div = Vec4.prototype.divide;
Vec4.prototype.dist = Vec4.prototype.distance;
Vec4.prototype.sqrDist = Vec4.prototype.squaredDistance;
Vec4.sub = Vec4.subtract;
Vec4.mul = Vec4.multiply;
Vec4.div = Vec4.divide;
Vec4.dist = Vec4.distance;
Vec4.sqrDist = Vec4.squaredDistance;
Vec4.sqrLen = Vec4.squaredLength;
Vec4.mag = Vec4.magnitude;
Vec4.length = Vec4.magnitude;
Vec4.len = Vec4.magnitude;
//#endregion
//#region ../../node_modules/.pnpm/gl-matrix@4.0.0-beta.2/node_modules/gl-matrix/dist/esm/vec2.js
/**
* 2 Dimensional Vector
*/
var Vec2 = class Vec2 extends Float32Array {
	/**
	* The number of bytes in a {@link Vec2}.
	*/
	static BYTE_LENGTH = 2 * Float32Array.BYTES_PER_ELEMENT;
	/**
	* Create a {@link Vec2}.
	*/
	constructor(...values) {
		switch (values.length) {
			case 2: {
				const v = values[0];
				if (typeof v === "number") super([v, values[1]]);
				else super(v, values[1], 2);
				break;
			}
			case 1: {
				const v = values[0];
				if (typeof v === "number") super([v, v]);
				else super(v, 0, 2);
				break;
			}
			default:
				super(2);
				break;
		}
	}
	/**
	* The x component of the vector. Equivalent to `this[0];`
	* @category Vector components
	*/
	get x() {
		return this[0];
	}
	set x(value) {
		this[0] = value;
	}
	/**
	* The y component of the vector. Equivalent to `this[1];`
	* @category Vector components
	*/
	get y() {
		return this[1];
	}
	set y(value) {
		this[1] = value;
	}
	/**
	* The r component of the vector. Equivalent to `this[0];`
	* @category Color components
	*/
	get r() {
		return this[0];
	}
	set r(value) {
		this[0] = value;
	}
	/**
	* The g component of the vector. Equivalent to `this[1];`
	* @category Color components
	*/
	get g() {
		return this[1];
	}
	set g(value) {
		this[1] = value;
	}
	/**
	* The magnitude (length) of this.
	* Equivalent to `Vec2.magnitude(this);`
	*
	* Magnitude is used because the `length` attribute is already defined by
	* TypedArrays to mean the number of elements in the array.
	*/
	get magnitude() {
		return Math.hypot(this[0], this[1]);
	}
	/**
	* Alias for {@link Vec2.magnitude}
	*/
	get mag() {
		return this.magnitude;
	}
	/**
	* The squared magnitude (length) of `this`.
	* Equivalent to `Vec2.squaredMagnitude(this);`
	*/
	get squaredMagnitude() {
		const x = this[0];
		const y = this[1];
		return x * x + y * y;
	}
	/**
	* Alias for {@link Vec2.squaredMagnitude}
	*/
	get sqrMag() {
		return this.squaredMagnitude;
	}
	/**
	* A string representation of `this`
	* Equivalent to `Vec2.str(this);`
	*/
	get str() {
		return Vec2.str(this);
	}
	/**
	* Copy the values from another {@link Vec2} into `this`.
	*
	* @param a the source vector
	* @returns `this`
	*/
	copy(a) {
		this.set(a);
		return this;
	}
	/**
	* Adds a {@link Vec2} to `this`.
	* Equivalent to `Vec2.add(this, this, b);`
	*
	* @param b - The vector to add to `this`
	* @returns `this`
	*/
	add(b) {
		this[0] += b[0];
		this[1] += b[1];
		return this;
	}
	/**
	* Subtracts a {@link Vec2} from `this`.
	* Equivalent to `Vec2.subtract(this, this, b);`
	*
	* @param b - The vector to subtract from `this`
	* @returns `this`
	*/
	subtract(b) {
		this[0] -= b[0];
		this[1] -= b[1];
		return this;
	}
	/**
	* Alias for {@link Vec2.subtract}
	*/
	sub(b) {
		return this;
	}
	/**
	* Multiplies `this` by a {@link Vec2}.
	* Equivalent to `Vec2.multiply(this, this, b);`
	*
	* @param b - The vector to multiply `this` by
	* @returns `this`
	*/
	multiply(b) {
		this[0] *= b[0];
		this[1] *= b[1];
		return this;
	}
	/**
	* Alias for {@link Vec2.multiply}
	*/
	mul(b) {
		return this;
	}
	/**
	* Divides `this` by a {@link Vec2}.
	* Equivalent to `Vec2.divide(this, this, b);`
	*
	* @param b - The vector to divide `this` by
	* @returns {Vec2} `this`
	*/
	divide(b) {
		this[0] /= b[0];
		this[1] /= b[1];
		return this;
	}
	/**
	* Alias for {@link Vec2.divide}
	*/
	div(b) {
		return this;
	}
	/**
	* Scales `this` by a scalar number.
	* Equivalent to `Vec2.scale(this, this, b);`
	*
	* @param b - Amount to scale `this` by
	* @returns `this`
	*/
	scale(b) {
		this[0] *= b;
		this[1] *= b;
		return this;
	}
	/**
	* Calculates `this` scaled by a scalar value then adds the result to `this`.
	* Equivalent to `Vec2.scaleAndAdd(this, this, b, scale);`
	*
	* @param b - The vector to add to `this`
	* @param scale - The amount to scale `b` by before adding
	* @returns `this`
	*/
	scaleAndAdd(b, scale) {
		this[0] += b[0] * scale;
		this[1] += b[1] * scale;
		return this;
	}
	/**
	* Calculates the euclidian distance between another {@link Vec2} and `this`.
	* Equivalent to `Vec2.distance(this, b);`
	*
	* @param b - The vector to calculate the distance to
	* @returns Distance between `this` and `b`
	*/
	distance(b) {
		return Vec2.distance(this, b);
	}
	/**
	* Alias for {@link Vec2.distance}
	*/
	dist(b) {
		return 0;
	}
	/**
	* Calculates the squared euclidian distance between another {@link Vec2} and `this`.
	* Equivalent to `Vec2.squaredDistance(this, b);`
	*
	* @param b The vector to calculate the squared distance to
	* @returns Squared distance between `this` and `b`
	*/
	squaredDistance(b) {
		return Vec2.squaredDistance(this, b);
	}
	/**
	* Alias for {@link Vec2.squaredDistance}
	*/
	sqrDist(b) {
		return 0;
	}
	/**
	* Negates the components of `this`.
	* Equivalent to `Vec2.negate(this, this);`
	*
	* @returns `this`
	*/
	negate() {
		this[0] *= -1;
		this[1] *= -1;
		return this;
	}
	/**
	* Inverts the components of `this`.
	* Equivalent to `Vec2.inverse(this, this);`
	*
	* @returns `this`
	*/
	invert() {
		this[0] = 1 / this[0];
		this[1] = 1 / this[1];
		return this;
	}
	/**
	* Sets each component of `this` to it's absolute value.
	* Equivalent to `Vec2.abs(this, this);`
	*
	* @returns `this`
	*/
	abs() {
		this[0] = Math.abs(this[0]);
		this[1] = Math.abs(this[1]);
		return this;
	}
	/**
	* Calculates the dot product of this and another {@link Vec2}.
	* Equivalent to `Vec2.dot(this, b);`
	*
	* @param b - The second operand
	* @returns Dot product of `this` and `b`
	*/
	dot(b) {
		return this[0] * b[0] + this[1] * b[1];
	}
	/**
	* Normalize `this`.
	* Equivalent to `Vec2.normalize(this, this);`
	*
	* @returns `this`
	*/
	normalize() {
		return Vec2.normalize(this, this);
	}
	/**
	* Creates a new, empty {@link Vec2}
	* @category Static
	*
	* @returns A new 2D vector
	*/
	static create() {
		return new Vec2();
	}
	/**
	* Creates a new {@link Vec2} initialized with values from an existing vector
	* @category Static
	*
	* @param a - Vector to clone
	* @returns A new 2D vector
	*/
	static clone(a) {
		return new Vec2(a);
	}
	/**
	* Creates a new {@link Vec2} initialized with the given values
	* @category Static
	*
	* @param x - X component
	* @param y - Y component
	* @returns A new 2D vector
	*/
	static fromValues(x, y) {
		return new Vec2(x, y);
	}
	/**
	* Copy the values from one {@link Vec2} to another
	* @category Static
	*
	* @param out - the receiving vector
	* @param a - The source vector
	* @returns `out`
	*/
	static copy(out, a) {
		out[0] = a[0];
		out[1] = a[1];
		return out;
	}
	/**
	* Set the components of a {@link Vec2} to the given values
	* @category Static
	*
	* @param out - The receiving vector
	* @param x - X component
	* @param y - Y component
	* @returns `out`
	*/
	static set(out, x, y) {
		out[0] = x;
		out[1] = y;
		return out;
	}
	/**
	* Adds two {@link Vec2}s
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - The first operand
	* @param b - The second operand
	* @returns `out`
	*/
	static add(out, a, b) {
		out[0] = a[0] + b[0];
		out[1] = a[1] + b[1];
		return out;
	}
	/**
	* Subtracts vector b from vector a
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - The first operand
	* @param b - The second operand
	* @returns `out`
	*/
	static subtract(out, a, b) {
		out[0] = a[0] - b[0];
		out[1] = a[1] - b[1];
		return out;
	}
	/**
	* Alias for {@link Vec2.subtract}
	* @category Static
	*/
	static sub(out, a, b) {
		return [0, 0];
	}
	/**
	* Multiplies two {@link Vec2}s
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - The first operand
	* @param b - The second operand
	* @returns `out`
	*/
	static multiply(out, a, b) {
		out[0] = a[0] * b[0];
		out[1] = a[1] * b[1];
		return out;
	}
	/**
	* Alias for {@link Vec2.multiply}
	* @category Static
	*/
	static mul(out, a, b) {
		return [0, 0];
	}
	/**
	* Divides two {@link Vec2}s
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - The first operand
	* @param b - The second operand
	* @returns `out`
	*/
	static divide(out, a, b) {
		out[0] = a[0] / b[0];
		out[1] = a[1] / b[1];
		return out;
	}
	/**
	* Alias for {@link Vec2.divide}
	* @category Static
	*/
	static div(out, a, b) {
		return [0, 0];
	}
	/**
	* Math.ceil the components of a {@link Vec2}
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - Vector to ceil
	* @returns `out`
	*/
	static ceil(out, a) {
		out[0] = Math.ceil(a[0]);
		out[1] = Math.ceil(a[1]);
		return out;
	}
	/**
	* Math.floor the components of a {@link Vec2}
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - Vector to floor
	* @returns `out`
	*/
	static floor(out, a) {
		out[0] = Math.floor(a[0]);
		out[1] = Math.floor(a[1]);
		return out;
	}
	/**
	* Returns the minimum of two {@link Vec2}s
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - The first operand
	* @param b - The second operand
	* @returns `out`
	*/
	static min(out, a, b) {
		out[0] = Math.min(a[0], b[0]);
		out[1] = Math.min(a[1], b[1]);
		return out;
	}
	/**
	* Returns the maximum of two {@link Vec2}s
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - The first operand
	* @param b - The second operand
	* @returns `out`
	*/
	static max(out, a, b) {
		out[0] = Math.max(a[0], b[0]);
		out[1] = Math.max(a[1], b[1]);
		return out;
	}
	/**
	* Math.round the components of a {@link Vec2}
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - Vector to round
	* @returns `out`
	*/
	static round(out, a) {
		out[0] = Math.round(a[0]);
		out[1] = Math.round(a[1]);
		return out;
	}
	/**
	* Scales a {@link Vec2} by a scalar number
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - The vector to scale
	* @param b - Amount to scale the vector by
	* @returns `out`
	*/
	static scale(out, a, b) {
		out[0] = a[0] * b;
		out[1] = a[1] * b;
		return out;
	}
	/**
	* Adds two Vec2's after scaling the second operand by a scalar value
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - The first operand
	* @param b - The second operand
	* @param scale - The amount to scale b by before adding
	* @returns `out`
	*/
	static scaleAndAdd(out, a, b, scale) {
		out[0] = a[0] + b[0] * scale;
		out[1] = a[1] + b[1] * scale;
		return out;
	}
	/**
	* Calculates the euclidian distance between two {@link Vec2}s
	* @category Static
	*
	* @param a - The first operand
	* @param b - The second operand
	* @returns distance between `a` and `b`
	*/
	static distance(a, b) {
		return Math.hypot(b[0] - a[0], b[1] - a[1]);
	}
	/**
	* Alias for {@link Vec2.distance}
	* @category Static
	*/
	static dist(a, b) {
		return 0;
	}
	/**
	* Calculates the squared euclidian distance between two {@link Vec2}s
	* @category Static
	*
	* @param a - The first operand
	* @param b - The second operand
	* @returns Squared distance between `a` and `b`
	*/
	static squaredDistance(a, b) {
		const x = b[0] - a[0];
		const y = b[1] - a[1];
		return x * x + y * y;
	}
	/**
	* Alias for {@link Vec2.distance}
	* @category Static
	*/
	static sqrDist(a, b) {
		return 0;
	}
	/**
	* Calculates the magnitude (length) of a {@link Vec2}
	* @category Static
	*
	* @param a - Vector to calculate magnitude of
	* @returns Magnitude of a
	*/
	static magnitude(a) {
		let x = a[0];
		let y = a[1];
		return Math.sqrt(x * x + y * y);
	}
	/**
	* Alias for {@link Vec2.magnitude}
	* @category Static
	*/
	static mag(a) {
		return 0;
	}
	/**
	* Alias for {@link Vec2.magnitude}
	* @category Static
	* @deprecated Use {@link Vec2.magnitude} to avoid conflicts with builtin `length` methods/attribs
	*
	* @param a - vector to calculate length of
	* @returns length of a
	*/
	static length(a) {
		return 0;
	}
	/**
	* Alias for {@link Vec2.magnitude}
	* @category Static
	* @deprecated Use {@link Vec2.mag}
	*/
	static len(a) {
		return 0;
	}
	/**
	* Calculates the squared length of a {@link Vec2}
	* @category Static
	*
	* @param a - Vector to calculate squared length of
	* @returns Squared length of a
	*/
	static squaredLength(a) {
		const x = a[0];
		const y = a[1];
		return x * x + y * y;
	}
	/**
	* Alias for {@link Vec2.squaredLength}
	*/
	static sqrLen(a, b) {
		return 0;
	}
	/**
	* Negates the components of a {@link Vec2}
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - Vector to negate
	* @returns `out`
	*/
	static negate(out, a) {
		out[0] = -a[0];
		out[1] = -a[1];
		return out;
	}
	/**
	* Returns the inverse of the components of a {@link Vec2}
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - Vector to invert
	* @returns `out`
	*/
	static inverse(out, a) {
		out[0] = 1 / a[0];
		out[1] = 1 / a[1];
		return out;
	}
	/**
	* Returns the absolute value of the components of a {@link Vec2}
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - Vector to compute the absolute values of
	* @returns `out`
	*/
	static abs(out, a) {
		out[0] = Math.abs(a[0]);
		out[1] = Math.abs(a[1]);
		return out;
	}
	/**
	* Normalize a {@link Vec2}
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - Vector to normalize
	* @returns `out`
	*/
	static normalize(out, a) {
		const x = a[0];
		const y = a[1];
		let len = x * x + y * y;
		if (len > 0) len = 1 / Math.sqrt(len);
		out[0] = a[0] * len;
		out[1] = a[1] * len;
		return out;
	}
	/**
	* Calculates the dot product of two {@link Vec2}s
	* @category Static
	*
	* @param a - The first operand
	* @param b - The second operand
	* @returns Dot product of `a` and `b`
	*/
	static dot(a, b) {
		return a[0] * b[0] + a[1] * b[1];
	}
	/**
	* Computes the cross product of two {@link Vec2}s
	* Note that the cross product must by definition produce a 3D vector.
	* For this reason there is also not instance equivalent for this function.
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - The first operand
	* @param b - The second operand
	* @returns `out`
	*/
	static cross(out, a, b) {
		const z = a[0] * b[1] - a[1] * b[0];
		out[0] = out[1] = 0;
		out[2] = z;
		return out;
	}
	/**
	* Performs a linear interpolation between two {@link Vec2}s
	* @category Static
	*
	* @param out - The receiving vector
	* @param a - The first operand
	* @param b - The second operand
	* @param t - Interpolation amount, in the range [0-1], between the two inputs
	* @returns `out`
	*/
	static lerp(out, a, b, t) {
		const ax = a[0];
		const ay = a[1];
		out[0] = ax + t * (b[0] - ax);
		out[1] = ay + t * (b[1] - ay);
		return out;
	}
	/**
	* Transforms the {@link Vec2} with a {@link Mat2}
	*
	* @param out - The receiving vector
	* @param a - The vector to transform
	* @param m - Matrix to transform with
	* @returns `out`
	*/
	static transformMat2(out, a, m) {
		const x = a[0];
		const y = a[1];
		out[0] = m[0] * x + m[2] * y;
		out[1] = m[1] * x + m[3] * y;
		return out;
	}
	/**
	* Transforms the {@link Vec2} with a {@link Mat2d}
	*
	* @param out - The receiving vector
	* @param a - The vector to transform
	* @param m - Matrix to transform with
	* @returns `out`
	*/
	static transformMat2d(out, a, m) {
		const x = a[0];
		const y = a[1];
		out[0] = m[0] * x + m[2] * y + m[4];
		out[1] = m[1] * x + m[3] * y + m[5];
		return out;
	}
	/**
	* Transforms the {@link Vec2} with a {@link Mat3}
	* 3rd vector component is implicitly '1'
	*
	* @param out - The receiving vector
	* @param a - The vector to transform
	* @param m - Matrix to transform with
	* @returns `out`
	*/
	static transformMat3(out, a, m) {
		const x = a[0];
		const y = a[1];
		out[0] = m[0] * x + m[3] * y + m[6];
		out[1] = m[1] * x + m[4] * y + m[7];
		return out;
	}
	/**
	* Transforms the {@link Vec2} with a {@link Mat4}
	* 3rd vector component is implicitly '0'
	* 4th vector component is implicitly '1'
	*
	* @param out - The receiving vector
	* @param a - The vector to transform
	* @param m - Matrix to transform with
	* @returns `out`
	*/
	static transformMat4(out, a, m) {
		const x = a[0];
		const y = a[1];
		out[0] = m[0] * x + m[4] * y + m[12];
		out[1] = m[1] * x + m[5] * y + m[13];
		return out;
	}
	/**
	* Rotate a 2D vector
	* @category Static
	*
	* @param out - The receiving {@link Vec2}
	* @param a - The {@link Vec2} point to rotate
	* @param b - The origin of the rotation
	* @param rad - The angle of rotation in radians
	* @returns `out`
	*/
	static rotate(out, a, b, rad) {
		const p0 = a[0] - b[0];
		const p1 = a[1] - b[1];
		const sinC = Math.sin(rad);
		const cosC = Math.cos(rad);
		out[0] = p0 * cosC - p1 * sinC + b[0];
		out[1] = p0 * sinC + p1 * cosC + b[1];
		return out;
	}
	/**
	* Get the angle between two 2D vectors
	* @category Static
	*
	* @param a - The first operand
	* @param b - The second operand
	* @returns The angle in radians
	*/
	static angle(a, b) {
		const x1 = a[0];
		const y1 = a[1];
		const x2 = b[0];
		const y2 = b[1];
		const mag = Math.sqrt(x1 * x1 + y1 * y1) * Math.sqrt(x2 * x2 + y2 * y2);
		const cosine = mag && (x1 * x2 + y1 * y2) / mag;
		return Math.acos(Math.min(Math.max(cosine, -1), 1));
	}
	/**
	* Set the components of a {@link Vec2} to zero
	* @category Static
	*
	* @param out - The receiving vector
	* @returns `out`
	*/
	static zero(out) {
		out[0] = 0;
		out[1] = 0;
		return out;
	}
	/**
	* Returns whether or not the vectors have exactly the same elements in the same position (when compared with ===)
	* @category Static
	*
	* @param a - The first vector.
	* @param b - The second vector.
	* @returns `true` if the vectors components are ===, `false` otherwise.
	*/
	static exactEquals(a, b) {
		return a[0] === b[0] && a[1] === b[1];
	}
	/**
	* Returns whether or not the vectors have approximately the same elements in the same position.
	* @category Static
	*
	* @param a - The first vector.
	* @param b - The second vector.
	* @returns `true` if the vectors are approximately equal, `false` otherwise.
	*/
	static equals(a, b) {
		const a0 = a[0];
		const a1 = a[1];
		const b0 = b[0];
		const b1 = b[1];
		return Math.abs(a0 - b0) <= 1e-6 * Math.max(1, Math.abs(a0), Math.abs(b0)) && Math.abs(a1 - b1) <= 1e-6 * Math.max(1, Math.abs(a1), Math.abs(b1));
	}
	/**
	* Returns a string representation of a vector
	* @category Static
	*
	* @param a - Vector to represent as a string
	* @returns String representation of the vector
	*/
	static str(a) {
		return `Vec2(${a.join(", ")})`;
	}
};
Vec2.prototype.sub = Vec2.prototype.subtract;
Vec2.prototype.mul = Vec2.prototype.multiply;
Vec2.prototype.div = Vec2.prototype.divide;
Vec2.prototype.dist = Vec2.prototype.distance;
Vec2.prototype.sqrDist = Vec2.prototype.squaredDistance;
Vec2.sub = Vec2.subtract;
Vec2.mul = Vec2.multiply;
Vec2.div = Vec2.divide;
Vec2.dist = Vec2.distance;
Vec2.sqrDist = Vec2.squaredDistance;
Vec2.sqrLen = Vec2.squaredLength;
Vec2.mag = Vec2.magnitude;
Vec2.length = Vec2.magnitude;
Vec2.len = Vec2.magnitude;
//#endregion
//#region src/utils/resource.ts
function loadImage(imageUrl) {
	return new Promise((resolve, reject) => {
		const img = document.createElement("img");
		img.onload = () => resolve(img);
		img.onerror = reject;
		img.src = imageUrl;
		img.crossOrigin = "anonymous";
		img.loading = "eager";
	});
}
function loadVideo(videoUrl) {
	return new Promise((resolve, reject) => {
		const video = document.createElement("video");
		let playing = false;
		let timeupdate = false;
		let rejected = false;
		video.addEventListener("playing", () => {
			playing = true;
			checkReady();
		}, true);
		video.addEventListener("timeupdate", () => {
			timeupdate = true;
			checkReady();
		}, true);
		video.addEventListener("error", (err) => {
			rejected = true;
			reject(err);
		}, true);
		function checkReady() {
			if (playing && timeupdate && !rejected) resolve(video);
		}
		video.src = videoUrl;
		video.playsInline = true;
		video.crossOrigin = "anonymous";
		video.autoplay = true;
		video.loop = true;
		video.muted = true;
		video.play();
	});
}
function loadResourceFromUrl(url, isVideo = false) {
	return isVideo ? loadVideo(url) : loadImage(url);
}
function loadResourceFromElement(element) {
	return new Promise((resolve, reject) => {
		if (element instanceof HTMLImageElement ? element.complete : element.readyState >= 3) resolve(element);
		else {
			element.onload = () => resolve(element);
			element.onerror = reject;
		}
	});
}
//#endregion
//#region src/bg-render/base.ts
var AbstractBaseRenderer = class {};
function clamp1(x) {
	return Math.max(1, x);
}
var BaseRenderer = class extends AbstractBaseRenderer {
	observer;
	flowSpeed = 1;
	currerntRenderScale = .75;
	constructor(canvas) {
		super();
		this.canvas = canvas;
		this.observer = new ResizeObserver(() => {
			const width = clamp1(canvas.clientWidth * window.devicePixelRatio * this.currerntRenderScale);
			const height = clamp1(canvas.clientHeight * window.devicePixelRatio * this.currerntRenderScale);
			this.onResize(width, height);
		});
		this.observer.observe(canvas);
	}
	setRenderScale(scale) {
		this.currerntRenderScale = scale;
		this.onResize(this.canvas.clientWidth * window.devicePixelRatio * this.currerntRenderScale, this.canvas.clientHeight * window.devicePixelRatio * this.currerntRenderScale);
	}
	/**
	* 当画板元素大小发生变化时此函数会被调用
	* 可以在此处重设和渲染器相关的尺寸设置
	* 考虑到初始化的时候元素不一定在文档中或出于某些特殊样式状态，尺寸长宽有可能会为 0，请注意进行特判处理
	* @param width 画板元素实际的物理像素宽度，有可能为 0
	* @param height 画板元素实际的物理像素高度，有可能为 0
	*/
	onResize(width, height) {
		this.canvas.width = width;
		this.canvas.height = height;
	}
	/**
	* 修改背景的流动速度，数字越大越快，默认为 1
	* @param speed 背景的流动速度，默认为 1
	*/
	setFlowSpeed(speed) {
		this.flowSpeed = speed;
	}
	dispose() {
		this.observer.disconnect();
		this.canvas.remove();
	}
	getElement() {
		return this.canvas;
	}
};
//#endregion
//#region src/bg-render/img.ts
function blurImage(imageData, radius, quality) {
	const pixels = imageData.data;
	const width = imageData.width;
	const height = imageData.height;
	let rsum;
	let gsum;
	let bsum;
	let asum;
	let x;
	let y;
	let i;
	let p;
	let p1;
	let p2;
	let yp;
	let yi;
	let yw;
	const wm = width - 1;
	const hm = height - 1;
	const rad1x = radius + 1;
	const divx = radius + rad1x;
	const rad1y = radius + 1;
	const div2 = 1 / (divx * (radius + rad1y));
	const r = [];
	const g = [];
	const b = [];
	const a = [];
	const vmin = [];
	const vmax = [];
	while (quality-- > 0) {
		yw = yi = 0;
		for (y = 0; y < height; y++) {
			rsum = pixels[yw] * rad1x;
			gsum = pixels[yw + 1] * rad1x;
			bsum = pixels[yw + 2] * rad1x;
			asum = pixels[yw + 3] * rad1x;
			for (i = 1; i <= radius; i++) {
				p = yw + ((i > wm ? wm : i) << 2);
				rsum += pixels[p++];
				gsum += pixels[p++];
				bsum += pixels[p++];
				asum += pixels[p];
			}
			for (x = 0; x < width; x++) {
				r[yi] = rsum;
				g[yi] = gsum;
				b[yi] = bsum;
				a[yi] = asum;
				if (y === 0) {
					vmin[x] = Math.min(x + rad1x, wm) << 2;
					vmax[x] = Math.max(x - radius, 0) << 2;
				}
				p1 = yw + vmin[x];
				p2 = yw + vmax[x];
				rsum += pixels[p1++] - pixels[p2++];
				gsum += pixels[p1++] - pixels[p2++];
				bsum += pixels[p1++] - pixels[p2++];
				asum += pixels[p1] - pixels[p2];
				yi++;
			}
			yw += width << 2;
		}
		for (x = 0; x < width; x++) {
			yp = x;
			rsum = r[yp] * rad1y;
			gsum = g[yp] * rad1y;
			bsum = b[yp] * rad1y;
			asum = a[yp] * rad1y;
			for (i = 1; i <= radius; i++) {
				yp += i > hm ? 0 : width;
				rsum += r[yp];
				gsum += g[yp];
				bsum += b[yp];
				asum += a[yp];
			}
			yi = x << 2;
			for (y = 0; y < height; y++) {
				pixels[yi] = rsum * div2 + .5 | 0;
				pixels[yi + 1] = gsum * div2 + .5 | 0;
				pixels[yi + 2] = bsum * div2 + .5 | 0;
				pixels[yi + 3] = asum * div2 + .5 | 0;
				if (x === 0) {
					vmin[y] = Math.min(y + rad1y, hm) * width;
					vmax[y] = Math.max(y - radius, 0) * width;
				}
				p1 = x + vmin[y];
				p2 = x + vmax[y];
				rsum += r[p1] - r[p2];
				gsum += g[p1] - g[p2];
				bsum += b[p1] - b[p2];
				asum += a[p1] - a[p2];
				yi += width << 2;
			}
		}
	}
}
//#endregion
//#region src/utils/clamp.ts
function clamp(x, min, max) {
	return Math.min(Math.max(x, min), max);
}
function clamp01(x) {
	return clamp(x, 0, 1);
}
//#endregion
//#region src/bg-render/mesh-renderer/cp-presets.ts
/** @internal */
const p = (cx, cy, x, y, ur = 0, vr = 0, up = 1, vp = 1) => Object.freeze({
	cx,
	cy,
	x,
	y,
	ur,
	vr,
	up,
	vp
});
/** @internal */
const preset = (width, height, conf) => Object.freeze({
	width,
	height,
	conf
});
const CONTROL_POINT_PRESETS = [
	preset(5, 5, [
		p(0, 0, -1, -1, 0, 0, 1, 1),
		p(1, 0, -.5, -1, 0, 0, 1, 1),
		p(2, 0, 0, -1, 0, 0, 1, 1),
		p(3, 0, .5, -1, 0, 0, 1, 1),
		p(4, 0, 1, -1, 0, 0, 1, 1),
		p(0, 1, -1, -.5, 0, 0, 1, 1),
		p(1, 1, -.5, -.5, 0, 0, 1, 1),
		p(2, 1, -.0052029684413368305, -.6131420587090777, 0, 0, 1, 1),
		p(3, 1, .5884227308309977, -.3990805107556692, 0, 0, 1, 1),
		p(4, 1, 1, -.5, 0, 0, 1, 1),
		p(0, 2, -1, 0, 0, 0, 1, 1),
		p(1, 2, -.4210024670505933, -.11895058380429502, 0, 0, 1, 1),
		p(2, 2, -.1019613423315412, -.023812118047224606, 0, -47, .629, .849),
		p(3, 2, .40275125660925437, -.06345314544600389, 0, 0, 1, 1),
		p(4, 2, 1, 0, 0, 0, 1, 1),
		p(0, 3, -1, .5, 0, 0, 1, 1),
		p(1, 3, .06801958477287173, .5205913248960121, -31, -45, 1, 1),
		p(2, 3, .21446469120128908, .29331610114301043, 6, -56, .566, 1.321),
		p(3, 3, .5, .5, 0, 0, 1, 1),
		p(4, 3, 1, .5, 0, 0, 1, 1),
		p(0, 4, -1, 1, 0, 0, 1, 1),
		p(1, 4, -.31378372841550195, 1, 0, 0, 1, 1),
		p(2, 4, .26153633255328046, 1, 0, 0, 1, 1),
		p(3, 4, .5, 1, 0, 0, 1, 1),
		p(4, 4, 1, 1, 0, 0, 1, 1)
	]),
	preset(4, 4, [
		p(0, 0, -1, -1, 0, 0, 1, 1),
		p(1, 0, -.33333333333333337, -1, 0, 0, 1, 1),
		p(2, 0, .33333333333333326, -1, 0, 0, 1, 1),
		p(3, 0, 1, -1, 0, 0, 1, 1),
		p(0, 1, -1, -.04495399932657351, 0, 0, 1, 1),
		p(1, 1, -.24056117520129328, -.22465999020104, 0, 0, 1, 1),
		p(2, 1, .334758885767489, -.00531297192779423, 0, 0, 1, 1),
		p(3, 1, .9989920470678106, -.3382976020775408, 8, 0, .566, 1.792),
		p(0, 2, -1, .33333333333333326, 0, 0, 1, 1),
		p(1, 2, -.3425497314639411, -27501607956947893e-21, 0, 0, 1, 1),
		p(2, 2, .3321437945812673, .1981776353859399, 0, 0, 1, 1),
		p(3, 2, 1, .0766118180296832, 0, 0, 1, 1),
		p(0, 3, -1, 1, 0, 0, 1, 1),
		p(1, 3, -.33333333333333337, 1, 0, 0, 1, 1),
		p(2, 3, .33333333333333326, 1, 0, 0, 1, 1),
		p(3, 3, 1, 1, 0, 0, 1, 1)
	]),
	preset(4, 4, [
		p(0, 0, -1, -1, 0, 0, 1, 2.075),
		p(1, 0, -.33333333333333337, -1, 0, 0, 1, 1),
		p(2, 0, .33333333333333326, -1, 0, 0, 1, 1),
		p(3, 0, 1, -1, 0, 0, 1, 1),
		p(0, 1, -1, -.4545779491139603, 0, 0, 1, 1),
		p(1, 1, -.33333333333333337, -.33333333333333337, 0, 0, 1, 1),
		p(2, 1, .0889403142626457, -.6025711180694033, -32, 45, 1, 1),
		p(3, 1, 1, -.33333333333333337, 0, 0, 1, 1),
		p(0, 2, -1, -.07402408608567845, 1, 0, 1, .094),
		p(1, 2, -.2719422694359541, .09775369930903222, 25, -18, 1.321, 0),
		p(2, 2, .19877414408395877, .4307383294587789, 48, -40, .755, .975),
		p(3, 2, 1, .33333333333333326, -37, 0, 1, 1),
		p(0, 3, -1, 1, 0, 0, 1, 1),
		p(1, 3, -.33333333333333337, 1, 0, 0, 1, 1),
		p(2, 3, .5125850864305672, 1, -20, -18, 0, 1.604),
		p(3, 3, 1, 1, 0, 0, 1, 1)
	]),
	preset(5, 5, [
		p(0, 0, -1, -1, 0, 0, 1, 1),
		p(1, 0, -.4501953125, -1, 0, 55, 1, 2.075),
		p(2, 0, .1953125, -1, 0, 0, 1, 1),
		p(3, 0, .4580078125, -1, 0, -25, 1, 1),
		p(4, 0, 1, -1, 0, 0, 1, 1),
		p(0, 1, -1, -.2514475377525607, -16, 0, 2.327, .943),
		p(1, 1, -.55859375, -.6609325945787148, 47, 0, 2.358, .377),
		p(2, 1, .232421875, -.5244375756366635, -66, -25, 1.855, 1.164),
		p(3, 1, .685546875, -.3753706470552125, 0, 0, 1, 1),
		p(4, 1, 1, -.6699125300354287, 0, 0, 1, 1),
		p(0, 2, -1, .035910396862284255, 0, 0, 1, 1),
		p(1, 2, -.4921875, .005378616309457018, 90, 23, 1, 1.981),
		p(2, 2, .021484375, -.1365043639066228, 0, 42, 1, 1),
		p(3, 2, .4765625, .05925822904974043, -30, 0, 1.95, .44),
		p(4, 2, 1, .251428847823418, 0, 0, 1, 1),
		p(0, 3, -1, .6968336464764276, -68, 0, 1, .786),
		p(1, 3, -.6904296875, .5890744209958608, -68, 0, 1, 1),
		p(2, 3, .1845703125, .3879238667654693, 61, 0, 1, 1),
		p(3, 3, .60546875, .4633553246018661, -47, -59, .849, 1.73),
		p(4, 3, 1, .6214021886400309, -33, 0, .377, 1.604),
		p(0, 4, -1, 1, 0, 0, 1, 1),
		p(1, 4, -.5, 1, 0, -73, 1, 1),
		p(2, 4, -.3271484375, 1, 0, -24, .314, 2.704),
		p(3, 4, .5, 1, 0, 0, 1, 1),
		p(4, 4, 1, 1, 0, 0, 1, 1)
	]),
	preset(5, 5, [
		p(0, 0, -1, -1),
		p(1, 0, -.6393, -1, 0, 0, 1, 2.3884),
		p(2, 0, 0, -1),
		p(3, 0, .5, -1),
		p(4, 0, 1, -1),
		p(0, 1, -1, -.2301),
		p(1, 1, -.6934, -.331, 0, -.7188, 1, 1.063),
		p(2, 1, -.0082, -.6814, -.2583, 0, 1.0964, 1),
		p(3, 1, .5836, -.531, .7029, 0, 1.5466, 1),
		p(4, 1, 1, -.6407),
		p(0, 2, -1, .2973, 0, 0, 1.8352, 1),
		p(1, 2, -.4082, .0602),
		p(2, 2, -.1803, -.3646, -.2998, 0, 1.1513, 1),
		p(3, 2, .477, -.1027, .8903, -.1882, 1.0807, .8551),
		p(4, 2, 1, -.2973),
		p(0, 3, -1, .7628, 0, 0, 2.3868, 1),
		p(1, 3, -.2525, .4814, -.8406, -1.6199, 1.4093, 1.2215),
		p(2, 3, .3607, .2814, -1.0713, -.0529, 1.0025, .7611),
		p(3, 3, .4885, .623, 0, .8184, 1, 1.2876),
		p(4, 3, 1, .5),
		p(0, 4, -1, 1),
		p(1, 4, -.4033, 1),
		p(2, 4, .2672, 1),
		p(3, 4, .5967, 1),
		p(4, 4, 1, 1)
	]),
	preset(5, 5, [
		p(0, 0, -1, -1),
		p(1, 0, -.2197, -1),
		p(2, 0, .0197, -1),
		p(3, 0, .8033, -1),
		p(4, 0, 1, -1),
		p(0, 1, -1, -.5451),
		p(1, 1, -.4885, -.4035, -1.0246, -.2268, 1.1936, .8005),
		p(2, 1, -.1213, -.2867, 0, -.6981, 1, .809),
		p(3, 1, .3246, -.5628, 0, -1.2188, 1, 1.044),
		p(4, 1, 1, -.3292),
		p(0, 2, -1, .1416),
		p(1, 2, -.341, -.0142, 0, -.4004, 1, 1.1293),
		p(2, 2, -.0393, -.023, .2915, -.373, 1.044, .9879),
		p(3, 2, .3148, -.0673, -.7853, -.8962, 1.4709, 1.0247),
		p(4, 2, 1, .1912),
		p(0, 3, -1, .5),
		p(1, 3, -.2689, .2743, .3404, -.5248, 1.0184, .4391),
		p(2, 3, .0721, .269, .5302, .1244, .6723, .3225),
		p(3, 3, .4148, .3894, -.6977, -.6783, .8094, .9247),
		p(4, 3, 1, .446),
		p(0, 4, -1, 1),
		p(1, 4, -.7311, 1),
		p(2, 4, .323, 1),
		p(3, 4, .6393, 1),
		p(4, 4, 1, 1)
	])
];
//#endregion
//#region src/bg-render/mesh-renderer/cp-generate.ts
/**
* @fileoverview
* 实验性的随机控制点生成函数算法
* 目的是取代原先大量的预设控制点代码
*/
const randomRange = (min, max) => Math.random() * (max - min) + min;
function smoothstep(edge0, edge1, x) {
	const t = clamp01((x - edge0) / (edge1 - edge0));
	return t * t * (3 - 2 * t);
}
function smoothifyControlPoints(conf, w, h, iterations = 2, factor = .5, factorIterationModifier = .1) {
	let grid = [];
	let f = factor;
	for (let j = 0; j < h; j++) {
		grid[j] = [];
		for (let i = 0; i < w; i++) grid[j][i] = conf[j * w + i];
	}
	const kernel = [
		[
			1,
			2,
			1
		],
		[
			2,
			4,
			2
		],
		[
			1,
			2,
			1
		]
	];
	const kernelSum = 16;
	for (let iter = 0; iter < iterations; iter++) {
		const newGrid = [];
		for (let j = 0; j < h; j++) {
			newGrid[j] = [];
			for (let i = 0; i < w; i++) {
				if (i === 0 || i === w - 1 || j === 0 || j === h - 1) {
					newGrid[j][i] = grid[j][i];
					continue;
				}
				let sumX = 0;
				let sumY = 0;
				let sumUR = 0;
				let sumVR = 0;
				let sumUP = 0;
				let sumVP = 0;
				for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
					const weight = kernel[dj + 1][di + 1];
					const nb = grid[j + dj][i + di];
					sumX += nb.x * weight;
					sumY += nb.y * weight;
					sumUR += nb.ur * weight;
					sumVR += nb.vr * weight;
					sumUP += nb.up * weight;
					sumVP += nb.vp * weight;
				}
				const avgX = sumX / kernelSum;
				const avgY = sumY / kernelSum;
				const avgUR = sumUR / kernelSum;
				const avgVR = sumVR / kernelSum;
				const avgUP = sumUP / kernelSum;
				const avgVP = sumVP / kernelSum;
				const cur = grid[j][i];
				const newX = cur.x * (1 - f) + avgX * f;
				const newY = cur.y * (1 - f) + avgY * f;
				const newUR = cur.ur * (1 - f) + avgUR * f;
				const newVR = cur.vr * (1 - f) + avgVR * f;
				const newUP = cur.up * (1 - f) + avgUP * f;
				const newVP = cur.vp * (1 - f) + avgVP * f;
				newGrid[j][i] = p(i, j, newX, newY, newUR, newVR, newUP, newVP);
			}
		}
		grid = newGrid;
		f = clamp01(f + factorIterationModifier);
	}
	for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) conf[j * w + i] = grid[j][i];
}
function noise(x, y) {
	return fract(Math.sin(x * 12.9898 + y * 78.233) * 43758.5453);
}
function fract(x) {
	return x - Math.floor(x);
}
function smoothNoise(x, y) {
	const x0 = Math.floor(x);
	const y0 = Math.floor(y);
	const x1 = x0 + 1;
	const y1 = y0 + 1;
	const xf = x - x0;
	const yf = y - y0;
	const u = xf * xf * (3 - 2 * xf);
	const v = yf * yf * (3 - 2 * yf);
	const n00 = noise(x0, y0);
	const n10 = noise(x1, y0);
	const n01 = noise(x0, y1);
	const n11 = noise(x1, y1);
	const nx0 = n00 * (1 - u) + n10 * u;
	const nx1 = n01 * (1 - u) + n11 * u;
	return nx0 * (1 - v) + nx1 * v;
}
function computeNoiseGradient(perlinFn, x, y, epsilon = .001) {
	const n1 = perlinFn(x + epsilon, y);
	const n2 = perlinFn(x - epsilon, y);
	const n3 = perlinFn(x, y + epsilon);
	const n4 = perlinFn(x, y - epsilon);
	const dx = (n1 - n2) / (2 * epsilon);
	const dy = (n3 - n4) / (2 * epsilon);
	const len = Math.sqrt(dx * dx + dy * dy) || 1;
	return [dx / len, dy / len];
}
function generateControlPoints(width, height, variationFraction = randomRange(.4, .6), normalOffset = randomRange(.3, .6), blendFactor = .8, smoothIters = Math.floor(randomRange(3, 5)), smoothFactor = randomRange(.2, .3), smoothModifier = randomRange(-.1, -.05)) {
	const w = width ?? Math.floor(randomRange(3, 6));
	const h = height ?? Math.floor(randomRange(3, 6));
	const conf = [];
	const dx = w === 1 ? 0 : 2 / (w - 1);
	const dy = h === 1 ? 0 : 2 / (h - 1);
	for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) {
		const baseX = (w === 1 ? 0 : i / (w - 1)) * 2 - 1;
		const baseY = (h === 1 ? 0 : j / (h - 1)) * 2 - 1;
		const isBorder = i === 0 || i === w - 1 || j === 0 || j === h - 1;
		const pertX = isBorder ? 0 : randomRange(-variationFraction * dx, variationFraction * dx);
		const pertY = isBorder ? 0 : randomRange(-variationFraction * dy, variationFraction * dy);
		let x = baseX + pertX;
		let y = baseY + pertY;
		const ur = isBorder ? 0 : randomRange(-60, 60);
		const vr = isBorder ? 0 : randomRange(-60, 60);
		const up = isBorder ? 1 : randomRange(.8, 1.2);
		const vp = isBorder ? 1 : randomRange(.8, 1.2);
		if (!isBorder) {
			const uNorm = (baseX + 1) / 2;
			const vNorm = (baseY + 1) / 2;
			const [nx, ny] = computeNoiseGradient(smoothNoise, uNorm, vNorm, .001);
			let offsetX = nx * normalOffset;
			let offsetY = ny * normalOffset;
			const weight = smoothstep(0, 1, Math.min(uNorm, 1 - uNorm, vNorm, 1 - vNorm));
			offsetX *= weight;
			offsetY *= weight;
			x = x * (1 - blendFactor) + (x + offsetX) * blendFactor;
			y = y * (1 - blendFactor) + (y + offsetY) * blendFactor;
		}
		conf.push(p(i, j, x, y, ur, vr, up, vp));
	}
	smoothifyControlPoints(conf, w, h, smoothIters, smoothFactor, smoothModifier);
	return preset(w, h, conf);
}
//#endregion
//#region \0raw:/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-kmgcccplayer-integration/packages/core/src/bg-render/mesh-renderer/mesh.frag.glsl
var mesh_frag_default = "precision highp float;\r\n\r\nvarying vec3 v_color;\r\nvarying vec2 v_uv;\r\nuniform sampler2D u_texture;\r\nuniform float u_time;\r\nuniform float u_volume;\r\nuniform float u_alpha;\r\n\r\n// 预计算常量\r\nconst float INV_255 = 1.0 / 255.0;\r\nconst float HALF_INV_255 = 0.5 / 255.0;\r\nconst float GRADIENT_NOISE_A = 52.9829189;\r\nconst vec2 GRADIENT_NOISE_B = vec2(0.06711056, 0.00583715);\r\n\r\n/* Gradient noise from Jorge Jimenez's presentation: */\r\n/* http://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare */\r\nfloat gradientNoise(in vec2 uv) {\r\n    return fract(GRADIENT_NOISE_A * fract(dot(uv, GRADIENT_NOISE_B)));\r\n}\r\n\r\n// 优化的旋转函数，避免重复计算sin/cos\r\nvec2 rot(vec2 v, float angle) {\r\n    float s = sin(angle);\r\n    float c = cos(angle);\r\n    return vec2(c * v.x - s * v.y, s * v.x + c * v.y);\r\n}\r\n\r\nvoid main() {\r\n    // 合并计算以减少指令数\r\n    float volumeEffect = u_volume * 2.0;\r\n    float timeVolume = u_time + u_volume;\r\n    \r\n    float dither = INV_255 * gradientNoise(gl_FragCoord.xy) - HALF_INV_255;\r\n    vec2 centeredUV = v_uv - vec2(0.2);\r\n    vec2 rotatedUV = rot(centeredUV, timeVolume * 2.0);\r\n    vec2 finalUV = rotatedUV * max(0.001, 1.0 - volumeEffect) + vec2(0.5);\r\n    \r\n    vec4 result = texture2D(u_texture, finalUV);\r\n    \r\n    float alphaVolumeFactor = u_alpha * max(0.5, 1.0 - u_volume * 0.5);\r\n    result.rgb *= v_color * alphaVolumeFactor;\r\n    result.a *= alphaVolumeFactor;\r\n    \r\n    result.rgb += vec3(dither);\r\n    \r\n    float dist = distance(v_uv, vec2(0.5));\r\n    float vignette = smoothstep(0.8, 0.3, dist);\r\n    float mask = 0.6 + vignette * 0.4;\r\n    result.rgb *= mask;\r\n    \r\n    gl_FragColor = result;\r\n}\r\n";
//#endregion
//#region \0raw:/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-kmgcccplayer-integration/packages/core/src/bg-render/mesh-renderer/mesh.vert.glsl
var mesh_vert_default = "precision highp float;\n\nattribute vec2 a_pos;\nattribute vec3 a_color;\nattribute vec2 a_uv;\nvarying vec3 v_color;\nvarying vec2 v_uv;\n\nuniform float u_aspect;\n\nvoid main() {\n    v_color = a_color;\n    v_uv = a_uv;\n    vec2 pos = a_pos;\n    if (u_aspect > 1.0) {\n        pos.y *= u_aspect;\n    } else {\n        pos.x /= u_aspect;\n    }\n    gl_Position = vec4(pos, 0.0, 1.0);\n}\n";
//#endregion
//#region src/bg-render/mesh-renderer/index.ts
/**
* @fileoverview
* 基于 Mesh Gradient 渐变渲染的渲染器
* 此渲染应该是 Apple Music 使用的背景渲染方式了
* 参考内容 https://movingparts.io/gradient-meshes
*/
const quadVertShader = `
attribute vec2 a_pos;
varying vec2 v_uv;
void main() {
    gl_Position = vec4(a_pos, 0.0, 1.0);
    v_uv = a_pos * 0.5 + 0.5;
}
`;
const quadFragShader = `
precision mediump float;
varying vec2 v_uv;
uniform sampler2D u_texture;
uniform float u_alpha;
void main() {
    vec4 color = texture2D(u_texture, v_uv);
    gl_FragColor = vec4(color.rgb, color.a * u_alpha);
}
`;
function easeInOutSine(x) {
	return -(Math.cos(Math.PI * x) - 1) / 2;
}
var GLProgram = class {
	gl;
	program;
	vertexShader;
	fragmentShader;
	attrs;
	constructor(gl, vertexShaderSource, fragmentShaderSource, label = "unknown") {
		this.label = label;
		this.gl = gl;
		this.vertexShader = this.createShader(gl.VERTEX_SHADER, vertexShaderSource);
		this.fragmentShader = this.createShader(gl.FRAGMENT_SHADER, fragmentShaderSource);
		this.program = this.createProgram();
		const num = gl.getProgramParameter(this.program, gl.ACTIVE_ATTRIBUTES);
		const attrs = {};
		for (let i = 0; i < num; i++) {
			const info = gl.getActiveAttrib(this.program, i);
			if (!info) continue;
			const location = gl.getAttribLocation(this.program, info.name);
			if (location === -1) continue;
			attrs[info.name] = location;
		}
		this.attrs = attrs;
	}
	createShader(type, source) {
		const gl = this.gl;
		const shader = gl.createShader(type);
		if (!shader) throw new Error("Failed to create shader");
		gl.shaderSource(shader, source);
		gl.compileShader(shader);
		if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(`Failed to compile shader for type ${type} "${this.label}": ${gl.getShaderInfoLog(shader)}`);
		return shader;
	}
	createProgram() {
		const gl = this.gl;
		const program = gl.createProgram();
		if (!program) throw new Error("Failed to create program");
		gl.attachShader(program, this.vertexShader);
		gl.attachShader(program, this.fragmentShader);
		gl.linkProgram(program);
		gl.validateProgram(program);
		if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
			const errLog = gl.getProgramInfoLog(program);
			gl.deleteProgram(program);
			throw new Error(`Failed to link program "${this.label}": ${errLog}`);
		}
		return program;
	}
	use() {
		this.gl.useProgram(this.program);
	}
	notFoundUniforms = /* @__PURE__ */ new Set();
	warnUniformNotFound(name) {
		if (this.notFoundUniforms.has(name)) return;
		this.notFoundUniforms.add(name);
		console.warn(`Failed to get uniform location for program "${this.label}": ${name}`);
	}
	setUniform1f(name, value) {
		const gl = this.gl;
		const location = gl.getUniformLocation(this.program, name);
		if (!location) this.warnUniformNotFound(name);
		else gl.uniform1f(location, value);
	}
	setUniform2f(name, value1, value2) {
		const gl = this.gl;
		const location = gl.getUniformLocation(this.program, name);
		if (!location) this.warnUniformNotFound(name);
		else gl.uniform2f(location, value1, value2);
	}
	setUniform1i(name, value) {
		const gl = this.gl;
		const location = gl.getUniformLocation(this.program, name);
		if (!location) this.warnUniformNotFound(name);
		else gl.uniform1i(location, value);
	}
	dispose() {
		const gl = this.gl;
		gl.deleteShader(this.vertexShader);
		gl.deleteShader(this.fragmentShader);
		gl.deleteProgram(this.program);
	}
};
var Mesh = class {
	vertexWidth = 0;
	vertexHeight = 0;
	vertexBuffer;
	indexBuffer;
	vertexData;
	indexData;
	vertexIndexLength = 0;
	wireFrame = false;
	constructor(gl, attrPos, attrColor, attrUV) {
		this.gl = gl;
		this.attrPos = attrPos;
		this.attrColor = attrColor;
		this.attrUV = attrUV;
		const vertexBuf = gl.createBuffer();
		if (!vertexBuf) throw new Error("Failed to create vertex buffer");
		this.vertexBuffer = vertexBuf;
		const indexBuf = gl.createBuffer();
		if (!indexBuf) throw new Error("Failed to create index buffer");
		this.indexBuffer = indexBuf;
		this.bind();
		this.vertexData = new Float32Array(0);
		this.indexData = new Uint16Array(0);
		this.resize(2, 2);
		this.update();
	}
	setWireFrame(enable) {
		this.wireFrame = enable;
		this.resize(this.vertexWidth, this.vertexHeight);
	}
	setVertexPos(vx, vy, x, y) {
		const idx = (vx + vy * this.vertexWidth) * 7;
		if (idx >= this.vertexData.length - 1) {
			console.warn("Vertex position out of range", idx, this.vertexData.length);
			return;
		}
		this.vertexData[idx] = x;
		this.vertexData[idx + 1] = y;
	}
	setVertexColor(vx, vy, r, g, b) {
		const idx = (vx + vy * this.vertexWidth) * 7 + 2;
		if (idx >= this.vertexData.length - 2) {
			console.warn("Vertex color out of range", idx, this.vertexData.length);
			return;
		}
		this.vertexData[idx] = r;
		this.vertexData[idx + 1] = g;
		this.vertexData[idx + 2] = b;
	}
	setVertexUV(vx, vy, x, y) {
		const idx = (vx + vy * this.vertexWidth) * 7 + 5;
		if (idx >= this.vertexData.length - 1) {
			console.warn("Vertex UV out of range", idx, this.vertexData.length);
			return;
		}
		this.vertexData[idx] = x;
		this.vertexData[idx + 1] = y;
	}
	setVertexData(vx, vy, x, y, r, g, b, u, v) {
		const idx = (vx + vy * this.vertexWidth) * 7;
		if (idx >= this.vertexData.length - 6) {
			console.warn("Vertex data out of range", idx, this.vertexData.length);
			return;
		}
		const data = this.vertexData;
		data[idx] = x;
		data[idx + 1] = y;
		data[idx + 2] = r;
		data[idx + 3] = g;
		data[idx + 4] = b;
		data[idx + 5] = u;
		data[idx + 6] = v;
	}
	getVertexIndexLength() {
		return this.vertexIndexLength;
	}
	draw() {
		const gl = this.gl;
		if (this.wireFrame) gl.drawElements(gl.LINES, this.vertexIndexLength, gl.UNSIGNED_SHORT, 0);
		else gl.drawElements(gl.TRIANGLES, this.vertexIndexLength, gl.UNSIGNED_SHORT, 0);
	}
	resize(vertexWidth, vertexHeight) {
		this.vertexWidth = vertexWidth;
		this.vertexHeight = vertexHeight;
		this.vertexIndexLength = vertexWidth * vertexHeight * 6;
		if (this.wireFrame) this.vertexIndexLength = vertexWidth * vertexHeight * 10;
		const vertexData = new Float32Array(vertexWidth * vertexHeight * 7);
		const indexData = new Uint16Array(this.vertexIndexLength);
		this.vertexData = vertexData;
		this.indexData = indexData;
		for (let y = 0; y < vertexHeight; y++) for (let x = 0; x < vertexWidth; x++) {
			const px = x / (vertexWidth - 1) * 2 - 1;
			const py = y / (vertexHeight - 1) * 2 - 1;
			this.setVertexPos(x, y, px || 0, py || 0);
			this.setVertexColor(x, y, 1, 1, 1);
			this.setVertexUV(x, y, x / (vertexWidth - 1), y / (vertexHeight - 1));
		}
		for (let y = 0; y < vertexHeight - 1; y++) for (let x = 0; x < vertexWidth - 1; x++) if (this.wireFrame) {
			const idx = (y * vertexWidth + x) * 10;
			indexData[idx] = y * vertexWidth + x;
			indexData[idx + 1] = y * vertexWidth + x + 1;
			indexData[idx + 2] = y * vertexWidth + x + 1;
			indexData[idx + 3] = (y + 1) * vertexWidth + x;
			indexData[idx + 4] = (y + 1) * vertexWidth + x;
			indexData[idx + 5] = (y + 1) * vertexWidth + x + 1;
			indexData[idx + 6] = (y + 1) * vertexWidth + x + 1;
			indexData[idx + 7] = y * vertexWidth + x + 1;
			indexData[idx + 8] = y * vertexWidth + x;
			indexData[idx + 9] = (y + 1) * vertexWidth + x;
		} else {
			const idx = (y * vertexWidth + x) * 6;
			indexData[idx] = y * vertexWidth + x;
			indexData[idx + 1] = y * vertexWidth + x + 1;
			indexData[idx + 2] = (y + 1) * vertexWidth + x;
			indexData[idx + 3] = y * vertexWidth + x + 1;
			indexData[idx + 4] = (y + 1) * vertexWidth + x + 1;
			indexData[idx + 5] = (y + 1) * vertexWidth + x;
		}
		const gl = this.gl;
		gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.indexBuffer);
		gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, this.indexData, gl.STATIC_DRAW);
	}
	bind() {
		const gl = this.gl;
		gl.bindBuffer(gl.ARRAY_BUFFER, this.vertexBuffer);
		gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.indexBuffer);
		if (this.attrPos !== void 0) {
			gl.vertexAttribPointer(this.attrPos, 2, gl.FLOAT, false, 28, 0);
			gl.enableVertexAttribArray(this.attrPos);
		}
		if (this.attrColor !== void 0) {
			gl.vertexAttribPointer(this.attrColor, 3, gl.FLOAT, false, 28, 8);
			gl.enableVertexAttribArray(this.attrColor);
		}
		if (this.attrUV !== void 0) {
			gl.vertexAttribPointer(this.attrUV, 2, gl.FLOAT, false, 28, 20);
			gl.enableVertexAttribArray(this.attrUV);
		}
	}
	update() {
		const gl = this.gl;
		gl.bindBuffer(gl.ARRAY_BUFFER, this.vertexBuffer);
		gl.bufferData(gl.ARRAY_BUFFER, this.vertexData, gl.DYNAMIC_DRAW);
	}
	dispose() {
		this.gl.deleteBuffer(this.vertexBuffer);
		this.gl.deleteBuffer(this.indexBuffer);
	}
};
var ControlPoint = class {
	color = Vec3.fromValues(1, 1, 1);
	location = Vec2.fromValues(0, 0);
	uTangent = Vec2.fromValues(0, 0);
	vTangent = Vec2.fromValues(0, 0);
	_uRot = 0;
	_vRot = 0;
	_uScale = 1;
	_vScale = 1;
	constructor() {
		Object.seal(this);
	}
	get uRot() {
		return this._uRot;
	}
	get vRot() {
		return this._vRot;
	}
	set uRot(value) {
		this._uRot = value;
		this.updateUTangent();
	}
	set vRot(value) {
		this._vRot = value;
		this.updateVTangent();
	}
	get uScale() {
		return this._uScale;
	}
	get vScale() {
		return this._vScale;
	}
	set uScale(value) {
		this._uScale = value;
		this.updateUTangent();
	}
	set vScale(value) {
		this._vScale = value;
		this.updateVTangent();
	}
	updateUTangent() {
		this.uTangent[0] = Math.cos(this._uRot) * this._uScale;
		this.uTangent[1] = Math.sin(this._uRot) * this._uScale;
	}
	updateVTangent() {
		this.vTangent[0] = -Math.sin(this._vRot) * this._vScale;
		this.vTangent[1] = Math.cos(this._vRot) * this._vScale;
	}
};
const H = Mat4.fromValues(2, -2, 1, 1, -3, 3, -2, -1, 0, 0, 1, 0, 1, 0, 0, 0);
const H_T = Mat4.clone(H).transpose();
function meshCoefficients(p00, p01, p10, p11, axis, output = Mat4.create()) {
	const l = (p) => p.location[axis];
	const u = (p) => p.uTangent[axis];
	const v = (p) => p.vTangent[axis];
	output[0] = l(p00);
	output[1] = l(p01);
	output[2] = v(p00);
	output[3] = v(p01);
	output[4] = l(p10);
	output[5] = l(p11);
	output[6] = v(p10);
	output[7] = v(p11);
	output[8] = u(p00);
	output[9] = u(p01);
	output[10] = 0;
	output[11] = 0;
	output[12] = u(p10);
	output[13] = u(p11);
	output[14] = 0;
	output[15] = 0;
	return output;
}
function colorCoefficients(p00, p01, p10, p11, axis, output = Mat4.create()) {
	const c = (p) => p.color[axis];
	output.fill(0);
	output[0] = c(p00);
	output[1] = c(p01);
	output[4] = c(p10);
	output[5] = c(p11);
	return output;
}
var Map2D = class {
	_width = 0;
	_height = 0;
	_data = [];
	constructor(width, height) {
		this.resize(width, height);
		Object.seal(this);
	}
	resize(width, height) {
		this._width = width;
		this._height = height;
		this._data = new Array(width * height).fill(0);
	}
	set(x, y, value) {
		this._data[x + y * this._width] = value;
	}
	get(x, y) {
		return this._data[x + y * this._width];
	}
	get width() {
		return this._width;
	}
	get height() {
		return this._height;
	}
};
var BHPMesh = class extends Mesh {
	/**
	* 细分级别，越大曲线越平滑，但是性能消耗也越大
	*/
	_subDivisions = 10;
	_controlPoints = new Map2D(3, 3);
	constructor(gl, attrPos, attrColor, attrUV) {
		super(gl, attrPos, attrColor, attrUV);
		this.resizeControlPoints(3, 3);
		Object.seal(this);
	}
	setWireFrame(enable) {
		super.setWireFrame(enable);
		this.updateMesh();
	}
	/**
	* 以当前的控制点矩阵大小和细分级别为参考重新设置细分级别，此操作不会重设控制点数据
	* @param subDivisions 细分级别
	*/
	resetSubdivition(subDivisions) {
		this._subDivisions = subDivisions;
		super.resize((this._controlPoints.width - 1) * subDivisions, (this._controlPoints.height - 1) * subDivisions);
	}
	/**
	* 重设控制点矩阵尺寸，将会重置所有控制点的颜色和坐标数据
	* 请在调用此方法后重新设置颜色和坐标，并调用 updateMesh 方法更新网格
	* @param width 控制点宽度数量，必须大于等于 2
	* @param height 控制点高度数量，必须大于等于 2
	*/
	resizeControlPoints(width, height) {
		if (!(width >= 2 && height >= 2)) throw new Error("Control points must be larger than 3x3 or equal");
		this._controlPoints.resize(width, height);
		for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
			const point = new ControlPoint();
			point.location.x = x / (width - 1) * 2 - 1;
			point.location.y = y / (height - 1) * 2 - 1;
			point.uTangent.x = 2 / (width - 1);
			point.vTangent.y = 2 / (height - 1);
			this._controlPoints.set(x, y, point);
		}
		this.resetSubdivition(this._subDivisions);
	}
	/**
	* 获取指定位置的控制点，然后可以设置颜色和坐标属性
	* 留意颜色属性和坐标属性的值范围均参考 WebGL 的定义
	* 即颜色各个组件取值 [0-1]，坐标取值 [-1, 1]
	* 点的位置以画面左下角为原点 (0,0)
	* @param x 需要获取的控制点的 x 坐标
	* @param y 需要获取的控制点的 y 坐标
	* @returns 控制点对象
	*/
	getControlPoint(x, y) {
		return this._controlPoints.get(x, y);
	}
	tempX = Mat4.create();
	tempY = Mat4.create();
	tempR = Mat4.create();
	tempG = Mat4.create();
	tempB = Mat4.create();
	tempXAcc = Mat4.create();
	tempYAcc = Mat4.create();
	tempRAcc = Mat4.create();
	tempGAcc = Mat4.create();
	tempBAcc = Mat4.create();
	tempUx = Vec4.create();
	tempUy = Vec4.create();
	tempUr = Vec4.create();
	tempUg = Vec4.create();
	tempUb = Vec4.create();
	precomputeMatrix(M, output) {
		output.copy(M).transpose();
		Mat4.mul(output, output, H);
		Mat4.mul(output, H_T, output);
		return output;
	}
	/**
	* 更新最终呈现的网格数据，此方法应在所有控制点或细分参数的操作完成后调用
	*/
	updateMesh() {
		const subDivM1 = this._subDivisions - 1;
		const tW = subDivM1 * (this._controlPoints.height - 1);
		const tH = subDivM1 * (this._controlPoints.width - 1);
		const controlPointsWidth = this._controlPoints.width;
		const controlPointsHeight = this._controlPoints.height;
		const subDivisions = this._subDivisions;
		const invSubDivM1 = 1 / subDivM1;
		const invTH = 1 / tH;
		const invTW = 1 / tW;
		const normPowers = new Float32Array(subDivisions * 4);
		for (let i = 0; i < subDivisions; i++) {
			const norm = i * invSubDivM1;
			const idx = i * 4;
			normPowers[idx] = norm ** 3;
			normPowers[idx + 1] = norm ** 2;
			normPowers[idx + 2] = norm;
			normPowers[idx + 3] = 1;
		}
		for (let x = 0; x < controlPointsWidth - 1; x++) for (let y = 0; y < controlPointsHeight - 1; y++) {
			const p00 = this._controlPoints.get(x, y);
			const p01 = this._controlPoints.get(x, y + 1);
			const p10 = this._controlPoints.get(x + 1, y);
			const p11 = this._controlPoints.get(x + 1, y + 1);
			meshCoefficients(p00, p01, p10, p11, "x", this.tempX);
			meshCoefficients(p00, p01, p10, p11, "y", this.tempY);
			colorCoefficients(p00, p01, p10, p11, "r", this.tempR);
			colorCoefficients(p00, p01, p10, p11, "g", this.tempG);
			colorCoefficients(p00, p01, p10, p11, "b", this.tempB);
			this.precomputeMatrix(this.tempX, this.tempXAcc);
			this.precomputeMatrix(this.tempY, this.tempYAcc);
			this.precomputeMatrix(this.tempR, this.tempRAcc);
			this.precomputeMatrix(this.tempG, this.tempGAcc);
			this.precomputeMatrix(this.tempB, this.tempBAcc);
			const sX = x / (controlPointsWidth - 1);
			const sY = y / (controlPointsHeight - 1);
			const baseVx = y * subDivisions;
			const baseVy = x * subDivisions;
			for (let u = 0; u < subDivisions; u++) {
				const vxOffset = baseVx + u;
				const uIdx = u * 4;
				this.tempUx[0] = normPowers[uIdx];
				this.tempUx[1] = normPowers[uIdx + 1];
				this.tempUx[2] = normPowers[uIdx + 2];
				this.tempUx[3] = normPowers[uIdx + 3];
				Vec4.transformMat4(this.tempUx, this.tempUx, this.tempXAcc);
				this.tempUy[0] = normPowers[uIdx];
				this.tempUy[1] = normPowers[uIdx + 1];
				this.tempUy[2] = normPowers[uIdx + 2];
				this.tempUy[3] = normPowers[uIdx + 3];
				Vec4.transformMat4(this.tempUy, this.tempUy, this.tempYAcc);
				this.tempUr[0] = normPowers[uIdx];
				this.tempUr[1] = normPowers[uIdx + 1];
				this.tempUr[2] = normPowers[uIdx + 2];
				this.tempUr[3] = normPowers[uIdx + 3];
				Vec4.transformMat4(this.tempUr, this.tempUr, this.tempRAcc);
				this.tempUg[0] = normPowers[uIdx];
				this.tempUg[1] = normPowers[uIdx + 1];
				this.tempUg[2] = normPowers[uIdx + 2];
				this.tempUg[3] = normPowers[uIdx + 3];
				Vec4.transformMat4(this.tempUg, this.tempUg, this.tempGAcc);
				this.tempUb[0] = normPowers[uIdx];
				this.tempUb[1] = normPowers[uIdx + 1];
				this.tempUb[2] = normPowers[uIdx + 2];
				this.tempUb[3] = normPowers[uIdx + 3];
				Vec4.transformMat4(this.tempUb, this.tempUb, this.tempBAcc);
				for (let v = 0; v < subDivisions; v++) {
					const vy = baseVy + v;
					const vIdx = v * 4;
					const v0 = normPowers[vIdx];
					const v1 = normPowers[vIdx + 1];
					const v2 = normPowers[vIdx + 2];
					const v3 = normPowers[vIdx + 3];
					const px = v0 * this.tempUx[0] + v1 * this.tempUx[1] + v2 * this.tempUx[2] + v3 * this.tempUx[3];
					const py = v0 * this.tempUy[0] + v1 * this.tempUy[1] + v2 * this.tempUy[2] + v3 * this.tempUy[3];
					const pr = v0 * this.tempUr[0] + v1 * this.tempUr[1] + v2 * this.tempUr[2] + v3 * this.tempUr[3];
					const pg = v0 * this.tempUg[0] + v1 * this.tempUg[1] + v2 * this.tempUg[2] + v3 * this.tempUg[3];
					const pb = v0 * this.tempUb[0] + v1 * this.tempUb[1] + v2 * this.tempUb[2] + v3 * this.tempUb[3];
					const uvX = sX + v * invTH;
					const uvY = 1 - sY - u * invTW;
					this.setVertexData(vxOffset, vy, px, py, pr, pg, pb, uvX, uvY);
				}
			}
		}
		this.update();
	}
};
var GLTexture = class {
	tex;
	constructor(gl, albumImageData) {
		this.gl = gl;
		const albumTexture = gl.createTexture();
		if (!albumTexture) throw new Error("Failed to create texture");
		this.tex = albumTexture;
		gl.activeTexture(gl.TEXTURE0);
		gl.bindTexture(gl.TEXTURE_2D, albumTexture);
		gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, albumImageData);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.MIRRORED_REPEAT);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT);
	}
	bind() {
		this.gl.bindTexture(this.gl.TEXTURE_2D, this.tex);
	}
	dispose() {
		this.gl.deleteTexture(this.tex);
	}
};
function createOffscreenCanvas(width, height) {
	if ("OffscreenCanvas" in window) return new OffscreenCanvas(width, height);
	const canvas = document.createElement("canvas");
	canvas.width = width;
	canvas.height = height;
	return canvas;
}
var MeshGradientRenderer = class extends BaseRenderer {
	gl;
	lastFrameTime = 0;
	frameTime = 0;
	lastTickTime = 0;
	smoothedVolume = 0;
	volume = 0;
	tickHandle = 0;
	maxFPS = 60;
	paused = false;
	staticMode = false;
	mainProgram;
	quadProgram;
	quadBuffer;
	fbo = null;
	fboTexture = null;
	manualControl = false;
	reduceImageSizeCanvas = createOffscreenCanvas(32, 32);
	targetSize = Vec2.fromValues(0, 0);
	currentSize = Vec2.fromValues(0, 0);
	isNoCover = true;
	meshStates = [];
	_disposed = false;
	frameCount = 0;
	lastFPSUpdate = 0;
	currentFPS = 0;
	enablePerformanceMonitoring = false;
	setManualControl(enable) {
		this.manualControl = enable;
	}
	setWireFrame(enable) {
		for (const state of this.meshStates) state.mesh.setWireFrame(enable);
	}
	getControlPoint(x, y) {
		return this.meshStates[this.meshStates.length - 1]?.mesh?.getControlPoint(x, y);
	}
	resizeControlPoints(width, height) {
		this.meshStates[this.meshStates.length - 1]?.mesh?.resizeControlPoints(width, height);
	}
	resetSubdivition(subDivisions) {
		this.meshStates[this.meshStates.length - 1]?.mesh?.resetSubdivition(subDivisions);
	}
	onTick(tickTime) {
		this.tickHandle = 0;
		if (this.paused) return;
		if (this._disposed) return;
		this.updatePerformanceStats(tickTime);
		const interval = 1e3 / this.maxFPS;
		const delta = tickTime - this.lastTickTime;
		if (delta < interval) {
			this.requestTick();
			return;
		}
		if (Number.isNaN(this.lastFrameTime)) this.lastFrameTime = tickTime;
		const frameDelta = tickTime - this.lastFrameTime;
		this.lastFrameTime = tickTime;
		this.lastTickTime = tickTime - delta % interval;
		this.frameTime += frameDelta * this.flowSpeed;
		if (!(this.onRedraw(this.frameTime, frameDelta) && this.staticMode)) this.requestTick();
		else if (this.staticMode) this.lastFrameTime = NaN;
	}
	checkIfResize() {
		const [tW, tH] = [this.targetSize.x, this.targetSize.y];
		const [cW, cH] = [this.currentSize.x, this.currentSize.y];
		if (tW !== cW || tH !== cH) {
			super.onResize(tW, tH);
			const gl = this.gl;
			gl.bindFramebuffer(gl.FRAMEBUFFER, null);
			gl.viewport(0, 0, tW, tH);
			this.currentSize.x = tW;
			this.currentSize.y = tH;
			if (tW > 0 && tH > 0) this.updateFBO(tW, tH);
		}
	}
	updateFBO(width, height) {
		const gl = this.gl;
		if (this.fbo) gl.deleteFramebuffer(this.fbo);
		if (this.fboTexture) gl.deleteTexture(this.fboTexture);
		this.fboTexture = gl.createTexture();
		gl.bindTexture(gl.TEXTURE_2D, this.fboTexture);
		gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
		this.fbo = gl.createFramebuffer();
		gl.bindFramebuffer(gl.FRAMEBUFFER, this.fbo);
		gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, this.fboTexture, 0);
		gl.bindFramebuffer(gl.FRAMEBUFFER, null);
	}
	onRedraw(tickTime, delta) {
		const latestMeshState = this.meshStates[this.meshStates.length - 1];
		let canBeStatic = false;
		const deltaFactor = delta / 500;
		if (latestMeshState) {
			latestMeshState.mesh.bind();
			if (this.manualControl) latestMeshState.mesh.updateMesh();
			if (this.isNoCover) {
				let hasActiveStates = false;
				for (let i = this.meshStates.length - 1; i >= 0; i--) {
					const state = this.meshStates[i];
					if (state.alpha <= -.1) {
						state.mesh.dispose();
						state.texture.dispose();
						this.meshStates.splice(i, 1);
					} else {
						state.alpha = Math.max(-.1, state.alpha - deltaFactor);
						hasActiveStates = true;
					}
				}
				canBeStatic = !hasActiveStates;
			} else {
				if (latestMeshState.alpha >= 1.1) {
					const deleted = this.meshStates.splice(0, this.meshStates.length - 1);
					for (const state of deleted) {
						state.mesh.dispose();
						state.texture.dispose();
					}
				} else latestMeshState.alpha = Math.min(1.1, latestMeshState.alpha + deltaFactor);
				canBeStatic = this.meshStates.length === 1 && latestMeshState.alpha >= 1.1;
			}
		}
		const gl = this.gl;
		this.checkIfResize();
		if (!this.fbo) return canBeStatic;
		gl.bindFramebuffer(gl.FRAMEBUFFER, null);
		gl.clearColor(0, 0, 0, 0);
		gl.clear(gl.COLOR_BUFFER_BIT);
		const lerpFactor = Math.min(1, delta / 100);
		this.smoothedVolume += (this.volume - this.smoothedVolume) * lerpFactor;
		for (const state of this.meshStates) {
			gl.bindFramebuffer(gl.FRAMEBUFFER, this.fbo);
			gl.disable(gl.BLEND);
			gl.clearColor(0, 0, 0, 0);
			gl.clear(gl.COLOR_BUFFER_BIT);
			this.mainProgram.use();
			gl.activeTexture(gl.TEXTURE0);
			this.mainProgram.setUniform1f("u_time", tickTime / 1e4);
			this.mainProgram.setUniform1f("u_aspect", this.manualControl ? 1 : this.canvas.width / this.canvas.height);
			this.mainProgram.setUniform1i("u_texture", 0);
			this.mainProgram.setUniform1f("u_volume", this.volume);
			this.mainProgram.setUniform1f("u_alpha", 1);
			state.texture.bind();
			state.mesh.bind();
			state.mesh.draw();
			gl.bindFramebuffer(gl.FRAMEBUFFER, null);
			gl.enable(gl.BLEND);
			gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
			this.quadProgram.use();
			this.quadProgram.setUniform1i("u_texture", 0);
			this.quadProgram.setUniform1f("u_alpha", easeInOutSine(clamp01(state.alpha)));
			gl.activeTexture(gl.TEXTURE0);
			gl.bindTexture(gl.TEXTURE_2D, this.fboTexture);
			gl.bindBuffer(gl.ARRAY_BUFFER, this.quadBuffer);
			const a_pos = this.quadProgram.attrs.a_pos;
			gl.vertexAttribPointer(a_pos, 2, gl.FLOAT, false, 0, 0);
			gl.enableVertexAttribArray(a_pos);
			gl.drawArrays(gl.TRIANGLES, 0, 6);
			gl.disableVertexAttribArray(a_pos);
		}
		gl.flush();
		return canBeStatic;
	}
	onTickBinded = this.onTick.bind(this);
	requestTick() {
		if (this._disposed) return;
		if (this.tickHandle === 0) this.tickHandle = requestAnimationFrame(this.onTickBinded);
	}
	constructor(canvas) {
		super(canvas);
		const gl = canvas.getContext("webgl", { antialias: true });
		if (!gl) throw new Error("WebGL not supported");
		if (!gl.getExtension("EXT_color_buffer_float")) console.warn("EXT_color_buffer_float not supported");
		if (!gl.getExtension("EXT_float_blend")) console.warn("EXT_float_blend not supported");
		if (!gl.getExtension("OES_texture_float_linear")) console.warn("OES_texture_float_linear not supported");
		if (!gl.getExtension("OES_texture_float")) console.warn("OES_texture_float not supported");
		this.gl = gl;
		gl.enable(gl.BLEND);
		gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
		gl.enable(gl.DEPTH_TEST);
		gl.depthFunc(gl.ALWAYS);
		this.mainProgram = new GLProgram(gl, mesh_vert_default, mesh_frag_default, "main-program-mg");
		this.quadProgram = new GLProgram(gl, quadVertShader, quadFragShader, "quad-program");
		const quadBuffer = gl.createBuffer();
		if (!quadBuffer) throw new Error("Failed to create quad buffer");
		this.quadBuffer = quadBuffer;
		gl.bindBuffer(gl.ARRAY_BUFFER, this.quadBuffer);
		gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
			-1,
			-1,
			1,
			-1,
			-1,
			1,
			-1,
			1,
			1,
			-1,
			1,
			1
		]), gl.STATIC_DRAW);
		this.requestTick();
	}
	onResize(width, height) {
		this.targetSize.x = Math.ceil(width);
		this.targetSize.y = Math.ceil(height);
		this.requestTick();
	}
	setStaticMode(enable) {
		this.staticMode = enable;
		this.lastFrameTime = performance.now();
		this.requestTick();
	}
	setFPS(fps) {
		this.maxFPS = fps;
	}
	pause() {
		if (this.tickHandle) {
			cancelAnimationFrame(this.tickHandle);
			this.tickHandle = 0;
		}
		this.paused = true;
	}
	resume() {
		this.paused = false;
		this.requestTick();
	}
	async setAlbum(albumSource, isVideo) {
		if (albumSource === void 0 || typeof albumSource === "string" && albumSource.trim().length === 0) {
			this.isNoCover = true;
			return;
		}
		let res = null;
		let blob = null;
		let remainRetryTimes = 5;
		while (!res && remainRetryTimes > 0) try {
			if (typeof albumSource === "string") if (!isVideo && "createImageBitmap" in window) {
				blob = await (await fetch(albumSource)).blob();
				res = await loadResourceFromUrl(URL.createObjectURL(blob), false);
			} else res = await loadResourceFromUrl(albumSource, isVideo);
			else res = await loadResourceFromElement(albumSource);
		} catch (error) {
			console.warn(`failed on loading album resource, retrying (${remainRetryTimes})`, {
				albumSource,
				error
			});
			remainRetryTimes--;
		}
		if (!res) {
			console.error("Failed to load album resource", albumSource);
			this.isNoCover = true;
			return;
		}
		this.isNoCover = false;
		const c = this.reduceImageSizeCanvas;
		const ctx = c.getContext("2d", { willReadFrequently: true });
		if (!ctx) throw new Error("Failed to create canvas context");
		ctx.clearRect(0, 0, c.width, c.height);
		const imgw = res instanceof HTMLVideoElement ? res.videoWidth : res.naturalWidth;
		const imgh = res instanceof HTMLVideoElement ? res.videoHeight : res.naturalHeight;
		if (imgw * imgh === 0) throw new Error("Invalid image size");
		let bitmap = null;
		try {
			if ("createImageBitmap" in window) if (blob) {
				bitmap = await createImageBitmap(blob, {
					resizeWidth: c.width,
					resizeHeight: c.height,
					resizeQuality: "low"
				});
				URL.revokeObjectURL(res.src);
			} else bitmap = await createImageBitmap(res, {
				resizeWidth: c.width,
				resizeHeight: c.height,
				resizeQuality: "low"
			});
		} catch (e) {
			console.warn("createImageBitmap failed", e);
		}
		if (bitmap) {
			ctx.drawImage(bitmap, 0, 0);
			bitmap.close();
		} else ctx.drawImage(res, 0, 0, imgw, imgh, 0, 0, c.width, c.height);
		const imageData = ctx.getImageData(0, 0, c.width, c.height);
		const pixels = imageData.data;
		for (let i = 0; i < pixels.length; i += 4) {
			let r = pixels[i];
			let g = pixels[i + 1];
			let b = pixels[i + 2];
			r = (r - 128) * .4 + 128;
			g = (g - 128) * .4 + 128;
			b = (b - 128) * .4 + 128;
			const gray = r * .3 + g * .59 + b * .11;
			r = gray * -2 + r * 3;
			g = gray * -2 + g * 3;
			b = gray * -2 + b * 3;
			r = (r - 128) * 1.7 + 128;
			g = (g - 128) * 1.7 + 128;
			b = (b - 128) * 1.7 + 128;
			pixels[i] = r * .75;
			pixels[i + 1] = g * .75;
			pixels[i + 2] = b * .75;
		}
		blurImage(imageData, 2, 4);
		if (this.manualControl && this.meshStates.length > 0) {
			this.meshStates[0].texture.dispose();
			this.meshStates[0].texture = new GLTexture(this.gl, imageData);
		} else {
			const newMesh = new BHPMesh(this.gl, this.mainProgram.attrs.a_pos, this.mainProgram.attrs.a_color, this.mainProgram.attrs.a_uv);
			newMesh.resetSubdivition(50);
			const chosenPreset = Math.random() > .8 ? generateControlPoints(6, 6) : CONTROL_POINT_PRESETS[Math.floor(Math.random() * CONTROL_POINT_PRESETS.length)];
			newMesh.resizeControlPoints(chosenPreset.width, chosenPreset.height);
			const uPower = 2 / (chosenPreset.width - 1);
			const vPower = 2 / (chosenPreset.height - 1);
			for (const cp of chosenPreset.conf) {
				const p = newMesh.getControlPoint(cp.cx, cp.cy);
				p.location.x = cp.x;
				p.location.y = cp.y;
				p.uRot = cp.ur * Math.PI / 180;
				p.vRot = cp.vr * Math.PI / 180;
				p.uScale = uPower * cp.up;
				p.vScale = vPower * cp.vp;
			}
			newMesh.updateMesh();
			const newState = {
				mesh: newMesh,
				texture: new GLTexture(this.gl, imageData),
				alpha: 0
			};
			this.meshStates.push(newState);
		}
		this.requestTick();
	}
	setLowFreqVolume(volume) {
		this.volume = volume / 10;
	}
	setHasLyric(_hasLyric) {}
	dispose() {
		super.dispose();
		if (this.tickHandle) {
			cancelAnimationFrame(this.tickHandle);
			this.tickHandle = 0;
		}
		this._disposed = true;
		this.mainProgram.dispose();
		this.quadProgram.dispose();
		this.gl.deleteBuffer(this.quadBuffer);
		if (this.fbo) this.gl.deleteFramebuffer(this.fbo);
		if (this.fboTexture) this.gl.deleteTexture(this.fboTexture);
		for (const state of this.meshStates) {
			state.mesh.dispose();
			state.texture.dispose();
		}
	}
	enablePerformanceMonitor(enable) {
		this.enablePerformanceMonitoring = enable;
		if (enable) {
			this.frameCount = 0;
			this.lastFPSUpdate = performance.now();
		}
	}
	getCurrentFPS() {
		return this.currentFPS;
	}
	updatePerformanceStats(tickTime) {
		if (!this.enablePerformanceMonitoring) return;
		this.frameCount++;
		if (tickTime - this.lastFPSUpdate > 1e3) {
			this.currentFPS = this.frameCount;
			this.frameCount = 0;
			this.lastFPSUpdate = tickTime;
		}
	}
};
//#endregion
//#region src/myplayer-background.ts
var BackgroundRender = class BackgroundRender {
	element;
	renderer;
	constructor(renderer, canvas) {
		this.renderer = renderer;
		this.element = canvas;
		canvas.style.pointerEvents = "none";
		canvas.style.contain = "strict";
	}
	static new(type) {
		const canvas = document.createElement("canvas");
		return new BackgroundRender(new type(canvas), canvas);
	}
	setRenderScale(scale) {
		this.renderer.setRenderScale(scale);
	}
	setFlowSpeed(speed) {
		this.renderer.setFlowSpeed(speed);
	}
	setStaticMode(enable) {
		this.renderer.setStaticMode(enable);
	}
	setFPS(fps) {
		this.renderer.setFPS(fps);
	}
	pause() {
		this.renderer.pause();
	}
	resume() {
		this.renderer.resume();
	}
	setLowFreqVolume(volume) {
		this.renderer.setLowFreqVolume(volume);
	}
	setHasLyric(hasLyric) {
		this.renderer.setHasLyric(hasLyric);
	}
	setAlbum(albumSource, isVideo) {
		return this.renderer.setAlbum(albumSource, isVideo);
	}
	getElement() {
		return this.element;
	}
	dispose() {
		this.renderer.dispose();
		this.element.remove();
	}
};
//#endregion
export { BackgroundRender, MeshGradientRenderer };

//# sourceMappingURL=amll-background.mjs.map