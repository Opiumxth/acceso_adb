import cv2
import zxingcpp

def leer_qr_camara():
    cap = cv2.VideoCapture(0)
    codigo_qr = None  # Initialize as None (in case no QR is found)

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        # Try to decode QR
        resultados = zxingcpp.read_barcodes(frame)
        
        if resultados:  # If QR detected
            codigo_qr = resultados[0].text  # Directly use .text (no need to decode)
            break

        cv2.imshow("Escanea tu codigo QR", frame)
        
        if cv2.waitKey(1) == 27:  # ESC key to exit
            break

    cap.release()
    cv2.destroyAllWindows()
    return codigo_qr  # Returns None if no QR was scanned