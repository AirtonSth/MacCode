declare module "qrcode" {
	export interface QRCodeToDataURLOptions {
		margin?: number;
		width?: number;
	}

	const QRCode: {
		toDataURL: (value: string, options?: QRCodeToDataURLOptions) => Promise<string>;
	};

	export default QRCode;
}
