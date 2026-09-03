//
//  Copyright (c) Dr. Michael Lauer Information Technology. All rights reserved.
//

#import "LTBTLESerialTransporter.h"

#import "LTSupportAutomotive.h"

#import "LTBTLEReadCharacteristicStream.h"
#import "LTBTLEWriteCharacteristicStream.h"

NSString* const LTBTLESerialTransporterDidUpdateSignalStrength = @"LTBTLESerialTransporterDidUpdateSignalStrength";
NSString* const LTBTLESerialTransporterDidStopScanning = @"LTBTLESerialTransporterDidStopScanning";
NSString* const LTBTLESerialTransporterDidStartScanning = @"LTBTLESerialTransporterDidStartScanning";
NSString* const LTBTLESerialTransporterDidDiscoverPeripheral = @"LTBTLESerialTransporterDidDiscoverPeripheral";
NSString* const LTBTLESerialTransporterConnectedPeripherals = @"LTBTLESerialTransporterConnectedPeripherals";
NSString* const LTBTLESerialTransporterSuccessfullConnectedPeripheral = @"LTBTLESerialTransporterSuccessfullConnectedPeripheral";

//#define DEBUG_THIS_FILE

#ifdef DEBUG_THIS_FILE
    #define XLOG LOG
#else
    #define XLOG(...)
#endif

@implementation LTBTLESerialTransporter
{
    CBCentralManager* _manager;
    NSArray<NSUUID*>* _identifiers;
    NSArray<CBUUID*>* _serviceUUIDs;
    BOOL _useServiceID;
    CBPeripheral* _adapter;
    CBCharacteristic* _reader;
    CBCharacteristic* _writer;
    
    NSMutableArray<CBPeripheral*>* _possibleAdapters;
    
    dispatch_queue_t _dispatchQueue;
    
    LTBTLESerialTransporterConnectionBlock _connectionBlock;
    LTBTLEReadCharacteristicStream* _inputStream;
    LTBTLEWriteCharacteristicStream* _outputStream;
    BOOL _adapterOwnsStreams;
    
    NSNumber* _signalStrength;
    NSTimer* _signalStrengthUpdateTimer;
    
    // RSSI-based selection when multiple identifiers are provided
    BOOL _rssiSelectionActive;
    NSMutableDictionary<NSUUID*, NSNumber*>* _rssiByPeripheral;
    NSMutableArray<CBPeripheral*>* _connectedCandidates;
}

#pragma mark -
#pragma mark Lifecycle

+(instancetype)transporterWithIdentifier:(NSUUID*)identifier serviceUUIDs:(NSArray<CBUUID*>*)serviceUUIDs
{
    NSArray<NSUUID*>* identifiers = identifier ? @[identifier] : nil;
    return [self transporterWithIdentifiers:identifiers serviceUUIDs:serviceUUIDs];
}

+(instancetype)transporterWithIdentifiers:(NSArray<NSUUID*>*)identifiers serviceUUIDs:(NSArray<CBUUID*>*)serviceUUIDs
{
    return [[self alloc] initWithIdentifiers:identifiers serviceUUIDs:serviceUUIDs];
}

-(instancetype)initWithIdentifiers:(NSArray<NSUUID*>*)identifiers serviceUUIDs:(NSArray<CBUUID*>*)serviceUUIDs
{
    if ( ! ( self = [super init] ) )
    {
        return nil;
    }
    
    _identifiers = [identifiers copy];
    _serviceUUIDs = serviceUUIDs;
    _useServiceID = false;
    
    _dispatchQueue = LTSupportAutomotive_backgroundQueue();
    _possibleAdapters = [NSMutableArray array];
    
    XLOG( @"Created w/ identifiers %@, services %@", _identifiers, _serviceUUIDs );
    
    return self;
}

-(void)dealloc
{
    [self disconnect];
}

#pragma mark -
#pragma mark API

-(void)connectWithBlock:(LTBTLESerialTransporterConnectionBlock)block
{
    _connectionBlock = block;
    
    _manager = [[CBCentralManager alloc] initWithDelegate:self queue:_dispatchQueue options:nil];
}

-(void)noteAdapterClosedStreams
{
    _adapterOwnsStreams = NO;
    _inputStream = nil;
    _outputStream = nil;
}

-(void)disconnect
{
    [self stopUpdatingSignalStrength];
    
    if ( ! _adapterOwnsStreams )
    {
        [_inputStream close];
        [_outputStream close];
    }
    _inputStream = nil;
    _outputStream = nil;
    _adapterOwnsStreams = NO;
    
    if ( _adapter )
    {
        [_manager cancelPeripheralConnection:_adapter];
    }
    
    [_possibleAdapters enumerateObjectsUsingBlock:^(CBPeripheral * _Nonnull peripheral, NSUInteger idx, BOOL * _Nonnull stop) {
        [self->_manager cancelPeripheralConnection:peripheral];
    }];
}

-(void)startUpdatingSignalStrengthWithInterval:(NSTimeInterval)interval
{
    [self stopUpdatingSignalStrength];
    
    _signalStrengthUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(onSignalStrengthUpdateTimerFired:) userInfo:nil repeats:YES];
}

-(void)stopUpdatingSignalStrength
{
    [_signalStrengthUpdateTimer invalidate];
    _signalStrengthUpdateTimer = nil;
}

#pragma mark -
#pragma mark NSTimer

-(void)onSignalStrengthUpdateTimerFired:(NSTimer*)timer
{
    if ( _adapter.state != CBPeripheralStateConnected )
    {
        return;
    }
    
    [_adapter readRSSI];
}

#pragma mark -
#pragma mark <CBCentralManagerDelegate>

-(void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    if ( central.state != CBManagerStatePoweredOn )
    {
        return;
    }
    NSArray<CBPeripheral*>* peripherals = [_manager retrieveConnectedPeripheralsWithServices:_serviceUUIDs];
    if ( peripherals.count )
    {
        LOG( @"CONNECTED (already) %@", _adapter );
        CBPeripheral* peripheral = peripherals.firstObject;
        if ( peripheral.state == CBPeripheralStateConnected )
        {
            peripheral.delegate = self;
            [self peripheral:peripheral didDiscoverServices:nil];
        }
        else
        {
            [_possibleAdapters addObject:peripheral];
            [self centralManager:central didDiscoverPeripheral:peripheral advertisementData:@{} RSSI:@127];
        }
        return;
    }
    
    if ( _identifiers.count )
    {
        peripherals = [_manager retrievePeripheralsWithIdentifiers:_identifiers];
    }
    if ( !peripherals.count )
    {
        // some devices are not advertising the service ID, hence we need to scan for all services
        if ( _useServiceID ) {
            [_manager scanForPeripheralsWithServices: _serviceUUIDs options:nil];
        } else {
            [_manager scanForPeripheralsWithServices:nil options:nil];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:LTBTLESerialTransporterDidStartScanning object:nil];
        return;
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:LTBTLESerialTransporterConnectedPeripherals object:peripherals];
    
    // When multiple known peripherals exist, use RSSI to pick the closest one.
    if ( peripherals.count > 1 )
    {
        _rssiSelectionActive = YES;
        _rssiByPeripheral = [NSMutableDictionary dictionary];
        _connectedCandidates = [NSMutableArray array];
    }
    
    for ( CBPeripheral* peripheral in peripherals )
    {
        if ( ![_possibleAdapters containsObject:peripheral] )
        {
            [_possibleAdapters addObject:peripheral];
        }
        peripheral.delegate = self;
        LOG( @"DISCOVER (cached) %@", peripheral );
        [_manager connectPeripheral:peripheral options:nil];
    }
}

-(void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral*)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI
{
    if ( _adapter )
    {
        LOG( @"[IGNORING] DISCOVER %@ (RSSI=%@) w/ advertisement %@", peripheral, RSSI, advertisementData );
        return;
    }
    
    LOG( @"DISCOVER %@ (RSSI=%@) w/ advertisement %@", peripheral, RSSI, advertisementData );
    [_possibleAdapters addObject:peripheral];
    peripheral.delegate = self;
    
    [[NSNotificationCenter defaultCenter] postNotificationName:LTBTLESerialTransporterDidDiscoverPeripheral object:[NSMutableArray arrayWithObjects:peripheral,advertisementData, nil]];
    [_manager connectPeripheral:peripheral options:nil];
}

-(void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral
{
    LOG( @"CONNECT %@", peripheral );
    
    if ( _rssiSelectionActive && !_adapter )
    {
        [_connectedCandidates addObject:peripheral];
        [peripheral readRSSI];
        
        // Schedule selection after a short window so multiple peripherals can report RSSI.
        // Each new connect resets the timer to allow late responders.
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(selectBestRSSICandidate) object:nil];
        [self performSelector:@selector(selectBestRSSICandidate) withObject:nil afterDelay:1.5];
        return;
    }
    
    [peripheral discoverServices:_serviceUUIDs];
}

-(void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    LOG( @"Failed to connect %@: %@", peripheral, error );
}

-(void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    LOG( @"Did disconnect %@: %@", peripheral, error );
    if ( peripheral == _adapter )
    {
        if ( ! _adapterOwnsStreams )
        {
            [_inputStream close];
            [_outputStream close];
        }
        _inputStream = nil;
        _outputStream = nil;
        _adapterOwnsStreams = NO;
        [central connectPeripheral:peripheral options:nil];
    }
}

#pragma mark -
#pragma mark <CBPeripheralDelegate>

-(void)peripheral:(CBPeripheral *)peripheral didReadRSSI:(NSNumber *)RSSI error:(NSError *)error
{
    if ( error )
    {
        LOG( @"Could not read signal strength for %@: %@", peripheral, error );
        return;
    }
    
    // Store RSSI for candidate selection
    if ( _rssiSelectionActive && !_adapter )
    {
        _rssiByPeripheral[peripheral.identifier] = RSSI;
        LOG( @"RSSI candidate %@ = %@", peripheral.name ?: peripheral.identifier, RSSI );
        return;
    }
    
    _signalStrength = RSSI;
    [[NSNotificationCenter defaultCenter] postNotificationName:LTBTLESerialTransporterDidUpdateSignalStrength object:self];
}

-(void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
    if ( _adapter && _adapter != peripheral )
    {
        LOG( @"[IGNORING] SERVICES %@: already committed to %@", peripheral, _adapter );
        [_manager cancelPeripheralConnection:peripheral];
        [_possibleAdapters removeObject:peripheral];
        return;
    }

    if ( _reader && _writer )
    {
        LOG( @"[IGNORING] SERVICES %@: %@ (streams ready)", peripheral, peripheral.services );
        return;
    }
    
    if ( error )
    {
        LOG( @"Could not discover services: %@", error );
        return;
    }
    
    if ( !peripheral.services.count )
    {
        LOG( @"Peripheral does not offer requested services" );
    
        [_manager cancelPeripheralConnection:peripheral];
        [_possibleAdapters removeObject:peripheral];
        return;
    }
    
    _adapter = peripheral;
    _adapter.delegate = self;
    if ( _manager.isScanning )
    {
        [_manager stopScan];
        [[NSNotificationCenter defaultCenter] postNotificationName:LTBTLESerialTransporterDidStopScanning object:self];
    }
    
    CBService* atCommChannel = peripheral.services.firstObject;
    [peripheral discoverCharacteristics:nil forService:atCommChannel];
}

-(void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error
{
    for ( CBCharacteristic* characteristic in service.characteristics )
    {
        if ( characteristic.properties & CBCharacteristicPropertyNotify )
        {
            LOG( @"Did see notify characteristic" );
            _reader = characteristic;
            
            //[peripheral readValueForCharacteristic:characteristic];
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
        }
        
        if ( characteristic.properties & CBCharacteristicPropertyWrite )
        {
            LOG( @"Did see write characteristic" );
            _writer = characteristic;
        }
    }
    
    if ( _reader && _writer )
    {
        [self connectionAttemptSucceeded];
    }
    else
    {
        [self connectionAttemptFailed];
    }
}

-(void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
#ifdef DEBUG_THIS_FILE
    NSString* debugString = [[NSString alloc] initWithData:characteristic.value encoding:NSUTF8StringEncoding];
    NSString* replacedWhitespace = [[debugString stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    XLOG( @"%@ >>> %@", peripheral, replacedWhitespace );
#endif
    
    if ( error )
    {
        LOG( @"Could not update value for characteristic %@: %@", characteristic, error );
        return;
    }
    
    [_inputStream characteristicDidUpdateValue];
}

-(void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    if ( error )
    {
        LOG( @"Could not write to characteristic %@: %@", characteristic, error );
        return;
    }
    
    [_outputStream characteristicDidWriteValue];
}

#pragma mark -
#pragma mark Helpers

-(void)selectBestRSSICandidate
{
    if ( _adapter )
    {
        // Already committed to an adapter (e.g. only one responded).
        return;
    }
    
    _rssiSelectionActive = NO;
    
    // Sort connected candidates by RSSI (highest = closest).
    CBPeripheral* best = nil;
    NSInteger bestRSSI = -999;
    
    for ( CBPeripheral* candidate in _connectedCandidates )
    {
        NSNumber* rssi = _rssiByPeripheral[candidate.identifier];
        NSInteger value = rssi ? rssi.integerValue : -999;
        LOG( @"RSSI selection: %@ (%@) = %ld", candidate.name ?: candidate.identifier.UUIDString, candidate.identifier, (long)value );
        if ( value > bestRSSI )
        {
            bestRSSI = value;
            best = candidate;
        }
    }
    
    if ( !best && _connectedCandidates.count )
    {
        // No RSSI data — fall back to first connected.
        best = _connectedCandidates.firstObject;
    }
    
    if ( best )
    {
        LOG( @"RSSI winner: %@ (RSSI=%ld)", best.name ?: best.identifier.UUIDString, (long)bestRSSI );
        [best discoverServices:_serviceUUIDs];
        
        // Disconnect the losers.
        for ( CBPeripheral* candidate in _connectedCandidates )
        {
            if ( candidate != best )
            {
                LOG( @"RSSI disconnect loser: %@", candidate.name ?: candidate.identifier.UUIDString );
                [_manager cancelPeripheralConnection:candidate];
                [_possibleAdapters removeObject:candidate];
            }
        }
    }
    
    _connectedCandidates = nil;
    _rssiByPeripheral = nil;
}

-(void)connectionAttemptSucceeded
{
    _inputStream = [[LTBTLEReadCharacteristicStream alloc] initWithCharacteristic:_reader];
    _outputStream = [[LTBTLEWriteCharacteristicStream alloc] initToCharacteristic:_writer];
    _adapterOwnsStreams = YES;
    _connectionBlock( _inputStream, _outputStream );
    _connectionBlock = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:LTBTLESerialTransporterSuccessfullConnectedPeripheral object:_adapter];
}

-(void)connectionAttemptFailed
{
    _connectionBlock( nil, nil );
    _connectionBlock = nil;
}

@end
